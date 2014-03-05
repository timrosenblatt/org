Grouper published a post yesterday [about how they use interactors](http://eng.joingrouper.com/blog/2014/03/03/rails-the-missing-parts-interactors) in their Rails app to help keep their `ActiveRecord` models as lean as possible. Somewhat comically, while doing a major refactor of the Heroku API, we'd independently arrived at a nearly identical pattern after learning the hard way that callbacks and large models were an easy route leading to an unmaintainable mess.

The main difference was in semantics: we called the resulting PORO's "mediators", a [design pattern](http://en.wikipedia.org/wiki/Mediator_pattern) that defines how a set of objects interact. I'm not one to quarrel over nomenclature, but I'll use the term "mediator" throughout this article because that's how I'm used to thinking about them.

The intent of this article is to build on what Grouper wrote by talking about some other nice patterns that we've built around the use of mediators/interactors.

## Lean Endpoints

One goal of our usage of mediators is to consolidate all the business logic that might otherwise have to reside in any API endpoint. Ideally what remains should be a set of request checks like authentication, ACL, and parameters; a single call down to a mediator; and response logic like serialization and status.

Here's a small excerpt from the API endpoint for creating an SSL Endpoint:

``` ruby
module API::Endpoints::APIV3
  class SSLEndpoints < Base
    ...

    namespace "/apps/:id/ssl-endpoints" do
      before do
        authorized!
        @ap = get_any_app!
        check_permissions!(:manage_domains, @ap)
        check_params!
      end

      post do
        @endpoint = API::Mediators::SSLEndpoints::Creator.run(
          auditor: self,
          app:     @ap,
          key:     v3_body_params[:private_key],
          pem:     v3_body_params[:certificate_chain],
          user:    current_user
        )
        respond serialize(@endpoint), status: 201
      end
    end

    ...
  end
end
```

This pattern helps produce a convention that helps keep important logic out of endpoints and in the more readily accessible mediator classes. It also keeps unit tests for the endpoints focused on what those endpoints are responsible for: authentication, parameter and permission checks, serialization, etc. For success cases, we can mock out the mediator's call and response and focus on doing more comprehensive tests on the business logic in the mediator's own unit tests. The entire stack still gets exercised at the integration test level, but we don't have to get into the same level of exhaustive testing there.

A mocked endpoint unit test might look like the following (note that the specs are using the [rr](https://github.com/rr/rr) mocking syntax):

``` ruby
# endpoint unit tests
describe API::Endpoints::APIV3::SSLEndpoints do
  ...

  describe "POST /apps/:id/ssl-endpoints" do
    it "calls into the mediator" do
      mock(API::Endpoints::APIV3::SSLEndpoints).run(hash_including({
        app:  @app,
        key:  "my-private-key",
        pem:  "my-pem",
        user: @user,
      })
      authorize "", @user.api_key
      header "Content-Type", "application/json"
      post "/apps/#{@app.name}/ssl-endpoints", MultiJson.encode({
        private_key:       "my-private-key",
        certificate_chain: "my-pem",
      })
    end
  end

  ...
end
```

The mediator unit tests will go into far greater detail and look something like this:

``` ruby
# mediator units tests
describe API::Mediators::SSLEndpoints::Creator do
  ...

  it "produces an SSL Endpoint" do
    endpoint = run
    assert_kind_of API::Models::SSLEndpoint, endpoint
  end

  it "makes a call to the Ion API to create the endpoint" do
    mock(IonAPI).create_endpoint
    run
  end

  ...

  private

  def run(options = {})
    API::Mediators::SSLEndpoints::Creator.run({
      app:  @app,
      key:  @key_contents,
      pem:  @pem_contents,
      user: @app.owner,
    }.merge(options))
  end
end
```

## Strong Preconditions

From within any mediator, we assume that a few preconditions have already been met:

* **Parameters:** All parameters are present in their expected form.
* **Models:** Rather than passing around abstract identifiers, parameters are materialized models so that no look-up logic needs to be included.
* **Security:** Security checks like authentication and access control have already been made.

Making these strong assumptions has a number of advantages:

* The complexity of the resulting code is reduce dramatically. We don't have to spend LOCs checking that objects are present or whether they're in their expected form (almost like working in a strongly typed language!).
* It eases testing as the boilerplate for checking parameter validation and the like can be consolidated elsewhere.
* Allows mediators to be called more easily from outside their normal context like from a debugging/operations console session.

## Mediators All the Way Down

One way to think about mediators is that they encapsulate a discrete piece of work that involves interaction between a set of objects; a piece of work that otherwise might have ended up in an unwieldy method on a model. Because units of work are often composable, just like those model methods would have been, it's a common pattern for mediators to make calls to other mediators.

Here's a small example of an app mediator that also deprovisions the app's installed add-ons:

``` ruby
module API::Mediators::Apps
  class Destroy < API::Mediators::Base
    ...

    def destroy_addons
      @app.addons.each do |addon|
        API::Mediators::Addons::Destroyer.run(
          addon:   addon,
          auditor: @auditor,
        )
      end
    end

    ...
  end
```

Of course it's important that your mediators have a clear call hierarchy so that you don't develop any circular dependencies, but over time we've found this practice to be mostly problem-free.

## Patterns Through Convention

While establishing mediators as the default unit of work, it's also a convenient time to start building other useful conventions into them. For example, we build in an auditing pattern so that we're still able to produce a trail of audit events even the mediator's work is performed from unexpected places like an operations console:

``` ruby
module API::Mediators::Apps
  class Destroy < API::Mediators::Base
    ...

    def call
      audit do
        ...
      end
    end

    private

    def audit(&block)
      @auditor.audit("destroy-app", target_app: @app, &block)
    end
  end
end
```

Another example of an established convention is to try and build out call bodies composed of a series of one-line calls to helpers that produces a very readable set of operations that any given mediator will perform:

``` ruby
module API::Mediators::Apps
  class Destroy < API::Mediators::Base
    ...

    def call
      audit do
        App.transaction do
          destroy_addons
          destroy_domains
          destroy_ssl_endpoints
          close_payment_method_history
          close_resource_histories
          delete_logplex_channel
          @app.destroy
        end
      end
    end

    ...
  end
```

A few years into working with the mediator pattern now, and I'd never go back. Although mediator calls are a little more verbose than they might have been as a model methods, they've allowed us to lean out the majority of our models to contain only basics like assocations, validations, and accessors.

Eliminating callbacks has also been a hugely important step forward in that it reduces production incidents caused by running innocent-looking code that results in devastating side effects, and results more transparent test code.

As a bonus, an unintended consequence of this refactoring is that we're now closer to being decoupled from `ActiveRecord` completely than we've ever been before, and having options available is great for peace of mind.