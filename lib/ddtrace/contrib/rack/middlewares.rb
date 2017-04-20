require 'ddtrace/ext/app_types'
require 'ddtrace/ext/http'

module Datadog
  module Contrib
    # Rack module includes middlewares that are required to trace any framework
    # and application built on top of Rack.
    module Rack
      # TraceMiddleware ensures that the Rack Request is properly traced
      # from the beginning to the end. The middleware adds the request span
      # in the Rack environment so that it can be retrieved by the underlying
      # application. If request tags are not set by the app, they will be set using
      # information available at the Rack level.
      class TraceMiddleware
        DEFAULT_CONFIG = {
          tracer: Datadog.tracer,
          default_service: 'rack'
        }.freeze

        def initialize(app, options = {})
          # access tracer configurations
          user_settings = DEFAULT_CONFIG.merge(options)
          @app = app
          @tracer = user_settings.fetch(:tracer)
          @service = user_settings.fetch(:default_service)

          # configure the Rack service
          @tracer.set_service_info(
            @service,
            'rack',
            Datadog::Ext::AppTypes::WEB
          )
        end

        def call(env)
          # get the current Rack request
          request = ::Rack::Request.new(env)

          # start a new request span and attach it to the current Rack environment;
          # we must ensure that the span `resource` is set later
          request_span = @tracer.trace(
            'rack.request',
            service: @service,
            resource: nil,
            span_type: Datadog::Ext::HTTP::TYPE
          )
          request.env[:datadog_rack_request_span] = request_span

          # call the rest of the stack
          status, headers, response = @app.call(env)
        rescue StandardError => e
          # catch exceptions that may be raised in the middleware chain
          # Note: if a middleware catches an Exception without re raising,
          # the Exception cannot be recorded here
          request_span.set_error(e)
          raise e
        ensure
          # Rack is a really low level interface and it doesn't provide any
          # advanced functionality like routers. Because of that, we assume that
          # the underlying framework or application has more knowledge about
          # the result for this request; `resource` and `tags` are expected to
          # be set in another level but if they're missing, reasonable defaults
          # are used.
          request_span.resource = "#{request.request_method} #{status}".strip unless request_span.resource
          request_span.set_tag('http.method', request.request_method) if request_span.get_tag('http.method').nil?
          request_span.set_tag('http.url', request.path_info) if request_span.get_tag('http.url').nil?
          request_span.set_tag('http.status_code', status) if request_span.get_tag('http.status_code').nil? && status

          # detect if the status code is a 5xx and flag the request span as an error
          # unless it has been already set by the underlying framework
          if status.to_s.start_with?('5') && request_span.status.zero?
            request_span.status = 1
            # in any case we don't touch the stacktrace if it has been set
            if request_span.get_tag(Datadog::Ext::Errors::STACK).nil?
              request_span.set_tag(Datadog::Ext::Errors::STACK, caller().join("\n"))
            end
          end

          request_span.finish()

          [status, headers, response]
        end
      end
    end
  end
end