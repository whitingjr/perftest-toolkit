module AMP
  module Toolkit
    module Buddhi
      # TestPlan Interface
      module TestPlan
        %i[amp_uri_path backend_metric_usage].each do |method_name|
          define_method(method_name) do
            raise 'Not Implemented'
          end
        end

        SERVICES_TEMPLATE = %i[id backend_version provider_key].freeze
        METRICS_TEMPLATE = %i[id service_id name parent_id].freeze
        APPLICATIONS_TEMPLATE = %i[id service_id state plan_id plan_name].freeze
        APPLICATION_KEY_TEMPLATE = %i[value user_key application_id service_id].freeze
        BACKEND_URL_PATH = '/transactions/authrep.xml'.freeze

        attr_reader :internal_backend, :backend_url, :backend_username, :backend_password, :http_port, :upstream_endpoint

        def initialize(services, opts)
          @internal_backend = opts[:internal_api]
          @backend_url = opts[:backend]
          @backend_username = opts[:username]
          @backend_password = opts[:password]
          @http_port = opts[:port]
          @services = services
          @upstream_endpoint = opts[:endpoint]
          @host = URI(opts[:apicast] || 'http://').host
        end

        def services
          @services.values.map do |service|
            service.select { |key, _| SERVICES_TEMPLATE.include? key }
          end
        end

        def service_tokens
          []
        end

        def metrics
          @services.values.flat_map do |metrics:, **|
            metrics.values.map do |metric|
              metric.select { |key, _| METRICS_TEMPLATE.include? key }
            end
          end
        end

        def usage_limits
          @services.values.flat_map { |usage_limits:, **| usage_limits }
        end

        def applications
          @services.values.flat_map do |applications:, **|
            applications.values.map do |app|
              app.select { |key, _| APPLICATIONS_TEMPLATE.include? key }
            end
          end
        end

        def application_keys
          @services.values.flat_map do |application_keys:, **|
            application_keys.map do |key|
              key.select { |k, _| APPLICATION_KEY_TEMPLATE.include? k }
            end
          end
        end

        def hosts_for(id)
          [[id, @host].compact.join('.')]
        end

        def app_auth_params(app_key)
          if app_key.key? :value
            {
              app_id: app_key[:application_id],
              app_key: app_key[:value]
            }
          else
            {
              user_key: app_key[:user_key]
            }
          end
        end

        def backend_uri(query_params)
          uri = URI::HTTP.build(path: BACKEND_URL_PATH, query: URI.encode_www_form(query_params))
          "#{uri.path}?#{uri.query}"
        end

        def apicast_service_info(id)
          return unless @services.key? id
          apicast_service_obj @services[id]
        end

        def apicast_service_obj(service)
          {
            id: service[:id],
            backend_authentication_type: 'provider_key',
            backend_authentication_value: service[:provider_key],
            backend_version: service[:backend_version],
            proxy: {
              api_backend: api_backend_endpoint,
              hosts: hosts_for(service[:id]),
              backend: {
                endpoint: backend_url
              },
              proxy_rules: proxy_rules(service)
            }
          }
        end

        def proxy_rules(service)
          if custom_path
            custom_proxy_rules(service)
          else
            test_plan_based_proxy_rules(service)
          end
        end

        def custom_proxy_rules(service)
          url_obj = URI.parse(upstream_endpoint)
          [
            {
              http_method: 'GET',
              pattern: "#{url_obj.path}",
              # first metric is the parent 'hits'
              metric_system_name: service[:metrics].values[1][:name],
              delta: 1
            }
          ]
        end

        def test_plan_based_proxy_rules(service)
          # first metric is the parent 'hits'
          service[:metrics].values.drop(1).each_with_index.map do |metric, idx|
            {
              http_method: 'GET',
              pattern: proxy_pattern(idx + 1),
              metric_system_name: metric[:name],
              delta: 1
            }
          end
        end

        def api_backend_endpoint
          url_obj = URI.parse(upstream_endpoint)
          url_obj.path = ''
          url_obj.query = nil
          url_obj.to_s
        end

        def proxy_pattern(n)
          format('/%<path>s', path: '1' * n)
        end

        def amp_path
          if custom_path
            custom_amp_path
          else
            test_plan_amp_path
          end
        end

        def custom_amp_path
          service = @services.values.sample
          app_key = service[:application_keys].sample
          app_id_auth = app_auth_params app_key

          url_obj = URI.parse(upstream_endpoint)
          # url_obj.query can be nil
          # concat query params from url_object and 3scale app keys
          new_query = URI.decode_www_form(String(url_obj.query)).concat(URI.decode_www_form(URI.encode_www_form(app_id_auth)))
          amp_uri_obj = amp_uri(url_obj.path, new_query)
          host = hosts_for(service[:id]).first
          path = "#{amp_uri_obj.path}?#{amp_uri_obj.query}"
          %("#{host}","#{path}")
        end

        def test_plan_amp_path
          service = @services.values.sample
          app_key = service[:application_keys].sample
          app_id_auth = app_auth_params app_key
          uri = amp_uri(amp_uri_path, app_id_auth)
          host = hosts_for(service[:id]).first
          path = "#{uri.path}?#{uri.query}"
          %("#{host}","#{path}")
        end

        def amp_uri(path, query_params)
          URI::HTTP.build(path: path, query: URI.encode_www_form(query_params))
        end

        def backend_path
          service = @services.values.sample
          app_key = service[:application_keys].sample
          app_id_auth = app_auth_params app_key

          query = {
            provider_key: service[:provider_key],
            service_id: service[:id]
          }.merge(app_id_auth)

          backend_metric_usage(service) do |metric|
            query["usage[#{metric[:name]}]".to_sym] = 1
          end

          backend_uri(query)
        end

        def metric_report(service_id, path)
          return {} unless @services.key? service_id
          service = @services[service_id]
          parent_metric = service[:metrics].values.first
          proxy_rules = apicast_service_obj(@services[service_id])[:proxy][:proxy_rules]
          matching_rules = proxy_rules.select { |r| filter_matching_rule(r, path) }
          matching_rules.each_with_object(Hash.new(0)) do |rule, acc|
            acc[parent_metric[:name]] += 1
            acc[rule[:metric_system_name]] += rule[:delta]
          end
        end

        def filter_matching_rule(rule, path)
          !/#{rule[:pattern]}/.match(path).nil?
        end

        # If upstream endpoint is full url with path, use that path for tests
        # otherwise, generate path pattern following specific test plan
        def custom_path
          url_obj = URI.parse(upstream_endpoint)
          url_obj.path.length > 1
        end
      end
    end
  end
end
