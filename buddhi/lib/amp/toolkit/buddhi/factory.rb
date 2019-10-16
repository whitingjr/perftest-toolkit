module AMP
  module Toolkit
    module Buddhi
      class Factory
        def self.call(portal:, services:, output:, **_options)
          client = ThreeScale.client(portal)
          File.open(output, 'w') do |file|
            service_ary(client, services).each do |service_id|
              Service.new(client, service_id).items.each do |host, path|
                file.puts %("#{host}","#{path}")
              end
            end
          end
        end

        def self.service_ary(client, services)
          if services.empty?
            client.list_services.map { |service| service.fetch('id') }
          else
            services.split(',')
          end
        end

        def self.validate_portal(portal_url)
          # parsing url before trying to create client
          # raises Invalid URL when syntax is incorrect
          ThreeScale::Helper.parse_uri(portal_url)
          ThreeScale.client(portal_url).list_accounts
          true
        rescue StandardError => e
          puts e
          false
        end
      end
    end
  end
end
