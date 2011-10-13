require 'active_record'
require 'helpers/model_helpers'
require 'helpers/controller_helpers'
module WepayRails

  class Configuration
    @@wepayable_class = nil
    @@wepayable_column = nil
    @@settings = nil

    def self.init_conf(klass, column, settings)
      @@wepayable_class, @@wepayable_column = klass, column
      @@settings = settings
    end

    def self.wepayable_class
      @@wepayable_class
    end

    def self.wepayable_column
      @@wepayable_column
    end

    def self.settings
      @@settings
    end
  end

  class Engine < Rails::Engine
    # Initializers
    initializer "WepayRails.initialize_wepay_rails" do |app|
      yml = Rails.root.join('config', 'wepay.yml').to_s
      settings = YAML.load_file(yml)[Rails.env].symbolize_keys
      klass, column = settings[:auth_code_location].split('.')
      Configuration.init_conf(eval(klass), column, settings)
    end
  end

  module Exceptions
    class AccessTokenError < StandardError; end
    class ExpiredTokenError < StandardError; end
    class InitializeCheckoutError < StandardError; end
    class AuthorizationError < StandardError; end
  end

  module Payments
    class Gateway
      include HTTParty

      base_uri @base_uri

      attr_accessor :wepay_access_token, :wepay_auth_code, :scope

      # Pass in the wepay access token that we got after the oauth handshake
      # and use it for ongoing comunique with Wepay.
      # This also relies heavily on there being a wepay.yml file in your
      # rails config directory - it must look like this:
      #
      #
      def initialize(*args)
        @wepay_access_token = args.first

        @wepay_config = WepayRails::Configuration.settings

        # Build the base uri
        # Default if there isn't a setting for version and/or api uri
        version = @wepay_config[:wepay_api_version].present? ? @wepay_config[:wepay_api_version] : "v2"
        api_uri = @wepay_config[:wepay_api_uri].present? ? @wepay_config[:wepay_api_uri] : "https://wepayapi.com"

        @base_uri = "#{api_uri}/#{version}"
      end

      def access_token(wepayable_object)
        auth_code = wepayable_object.send(WepayRails::Configuration.wepayable_column.to_s)
        query = {
          :client_id => @wepay_config[:client_id],
          :client_secret => @wepay_config[:client_secret],
          :redirect_uri => @wepay_config[:redirect_uri],
          :code => auth_code
        }
        response = self.class.get("#{@base_uri}/oauth2/token", :query => query)
        json = JSON.parse(response.body)

        if json.has_key?("error")
          if json.has_key?("error_description")
            if ['invalid code parameter','the code has expired'].include?(json['error_description'])
              raise WepayRails::Exceptions::ExpiredTokenError.new("Token either expired or invalid: #{json["error_description"]}")
            end
            raise WepayRails::Exceptions::AccessTokenError.new(json["error_description"])
          end
        end

        raise WepayRails::Exceptions::AccessTokenError.new("A problem occurred trying to get the access token: #{json.inspect}") unless json.has_key?("access_token")

        @wepay_access_token = json["access_token"]
      end

      # Get the auth code url that will be used to fetch the auth code for the customer
      # arguments are the redirect_uri and an array of permissions that your application needs
      # ex. ['manage_accounts','collect_payments','view_balance','view_user']
      def auth_code_url(wepayable_object)
        parms = {
          :client_id => @wepay_config[:client_id],
          :redirect_uri => @wepay_config[:redirect_uri],
          :scope => WepayRails::Configuration.settings[:scope].join(',')
        }

        query = parms.map do |k, v|
          "#{k.to_s}=#{v}"
        end.join('&')

        "#{@base_uri}/oauth2/authorize?#{query}"
      end

      def wepay_auth_header
        {'Authorization' => "Bearer: #{@wepay_access_token}"}
      end

      # Make a call to wepay to get the user info. This will only make one call
      # per request. Any subsequent calls to wepay_user will return the data
      # retrieved from the first call.
      def wepay_user
        user_api = lambda {|headers|
          response = self.class.get("#{@base_uri}/user", {:headers => headers})
          JSON.parse(response.body)
        }

        @wepay_user ||= user_api.call(wepay_auth_header)
      end

      # Many of the settings you pass in here are already factored in from
      # the wepay.yml file and only need to be overridden if you insist on doing
      # so when this method is called. The following list of key values are pulled
      # in for you from your wepay.yml file:
      #
      # Note: @wepay_config is your wepay.yml as a Hash
      # :callback_uri     => @wepay_config[:ipn_callback_uri],
      # :redirect_uri     => @wepay_config[:checkout_redirect_uri],
      # :fee_payer        => @wepay_config[:fee_payer],
      # :type             => @wepay_config[:checkout_type],
      # :charge_tax       => @wepay_config[:charge_tax] ? 1 : 0,
      # :app_fee          => @wepay_config[:app_fee],
      # :auto_capture     => @wepay_config[:auto_capture] ? 1 : 0,
      # :require_shipping => @wepay_config[:require_shipping] ? 1 : 0,
      # :shipping_fee     => @wepay_config[:shipping_fee],
      # :charge_tax       => @wepay_config[:charge_tax],
      # :account_id       => wepay_user['account_id'] # wepay-rails goes and gets this for you, but you can override it if you want to.
      #
      #
      # params hash key values possibilities are:
      # Parameter:	Required:	Description:
      # :account_id	Yes	The unique ID of the account you want to create a checkout for.
      # :short_description	Yes	A short description of what is being paid for.
      # :long_description	No	A long description of what is being paid for.
      # :type	Yes	The the checkout type (one of the following: GOODS, SERVICE, DONATION, or PERSONAL)
      # :reference_id	No	The unique reference id of the checkout (set by the application in /checkout/create
      # :amount	Yes	The amount that the payer will pay.
      # :app_fee	No	The amount that the application will receive in fees.
      # :fee_payer	  No	Who will pay the fees (WePay's fees and any app fees). Set to "Payer" to charge fees to the person paying (Payer will pay amount + fees, payee will receive amount). Set to "Payee" to charge fees to the person receiving money (Payer will pay amount, Payee will receive amount - fees). Defaults to "Payer".
      # :redirect_uri 	No	The uri the payer will be redirected to after paying.
      # :callback_uri	  No	The uri that will receive any Instant Payment Notifications sent. Needs to be a full uri (ex https://www.wepay.com )
      # :auto_capture	No	A boolean value (0 or 1). Default is 1. If set to 0 then the payment will not automatically be released to the account and will be held by WePay in payment state 'reserved'. To release funds to the account you must call /checkout/capture
      # :require_shipping	No	A boolean value (0 or 1). If set to 1 then the payer will be asked to enter a shipping address when they pay. After payment you can retrieve this shipping address by calling /checkout
      # :shipping_fee	No	The amount that you want to charge for shipping.
      # :charge_tax	No	A boolean value (0 or 1). If set to 1 and the account has a relevant tax entry (see /account/set_tax), then tax will be charged.
      def perform_checkout(parms)
        defaults = {
            :callback_uri     => @wepay_config[:ipn_callback_uri],
            :redirect_uri     => @wepay_config[:checkout_redirect_uri],
            :fee_payer        => @wepay_config[:fee_payer],
            :type             => @wepay_config[:checkout_type],
            :charge_tax       => @wepay_config[:charge_tax] ? 1 : 0,
            :app_fee          => @wepay_config[:app_fee],
            :auto_capture     => @wepay_config[:auto_capture] ? 1 : 0,
            :require_shipping => @wepay_config[:require_shipping] ? 1 : 0,
            :shipping_fee     => @wepay_config[:shipping_fee],
            :account_id       => @wepay_config[:account_id]
        }.merge(parms)

        response = self.class.get("#{@base_uri}/checkout/create", {:headers => wepay_auth_header}.merge!(:query => defaults))
        JSON.parse(response.body)
      end

      def lookup_checkout(*args)
        checkout_id = args.first
        parms = args.last if args.last.is_a?(Hash)

        response = self.class.get("#{@base_uri}/checkout", {:headers => wepay_auth_header}.merge!(:query => {:checkout_id => checkout_id}))
        JSON.parse(response.body)
      end

      def create_account(params)
        response = self.class.post("#{@base_uri}/account/create", {:headers => wepay_auth_header}.merge!(:body => params))
        JSON.parse(response.body)
      end
      
      def get_account(account_id)
        response = self.class.get("#{@base_uri}/account", {:headers => wepay_auth_header}.merge!(:query => { account_id: account_id }))
        JSON.parse(response.body)
      end

      def find_account(args)
        response = self.class.get("#{@base_uri}/account/find", {:headers => wepay_auth_header}.merge!(:query => args))
        JSON.parse(response.body)
      end

      def modify_account(params)
        response = self.class.put("#{@base_uri}/account/find", {:headers => wepay_auth_header}.merge!(:body => args))
        JSON.parse(response.body)
      end

      def delete_account(account_id)
        response = self.class.delete("#{@base_uri}/account", {:headers => wepay_auth_header}.merge!(:query => { account_id: account_id }))
        JSON.parse(response.body)
      end

      def get_account_balance(account_id)
        response = self.class.get("#{@base_uri}/account/balance", {:headers => wepay_auth_header}.merge!(:query => { account_id: account_id }))
        JSON.parse(response.body)
      end
    end

    include WepayRails::Exceptions
    include WepayRails::Helpers::ControllerHelpers
  end

  def self.included(base)
    base.extend WepayRails::Helpers::ModelHelpers
  end
end
ActiveRecord::Base.send(:include, WepayRails)
