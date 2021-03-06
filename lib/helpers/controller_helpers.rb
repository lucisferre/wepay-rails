module WepayRails
  module Helpers
    module ControllerHelpers

      def redirect_to_wepay_for_auth(wepayable_object, params = {})
        # Initially set a reference ID to the column created for the wepayable
        # so that when the redirect back from wepay happens, we can reference
        # the original wepayable, and then save the new auth code into the reference ID's
        # place
        ref_id = Digest::SHA1.hexdigest("#{Time.now.to_i+rand(4)}")
        session[unique_wepay_auth_token_key] = ref_id
        wepayable_object.update_attribute(WepayRails::Configuration.wepayable_column.to_sym, ref_id)

        redirect_to wepay_gateway.auth_code_url(params)
      end

      # @deprecated Use wepay_gateway instead of gateway
      def gateway
        warn "[DEPRECATION] Use wepay_gateway instead of gateway"
        wepay_gateway
      end

      def wepay_gateway
        @gateway ||= WepayRails::Payments::Gateway.new(wepay_access_token)
      end

      # From https://stage.wepay.com/developer/tutorial/authorization
      # Request
      # https://stage.wepay.com/v2/oauth2/token
      # ?client_id=[your client id]
      # &redirect_uri=[your redirect uri ex. 'http://exampleapp.com/wepay']
      # &client_secret=[your client secret]
      # &code=[the code you got in step one]
      #
      # Response
      # {"user_id":"123456","access_token":"1337h4x0rzabcd12345","token_type":"BEARER"} Example
      def initialize_wepay_access_token(wepayable_object)
        session[unique_wepay_access_token_key] = wepay_gateway.access_token(wepayable_object)
        return
      end

      # Since we are saving the access token in the session,
      # ensure key uniqueness. Might be a good idea to have this
      # be a setting in the wepay.yml file.
      def unique_wepay_access_token_key
        :IODDR8856UUFG6788
      end

      def unique_wepay_auth_token_key
        :J8876GFUU6588RDDO
      end

      # Access token is the OAUTH access token that is used for future
      # comunique
      def wepay_access_token
        session[unique_wepay_access_token_key]
      end

      def wepay_access_token_exists?
        wepay_access_token.present?
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
      def init_checkout_and_send_user_to_wepay(params)
        response = wepay_gateway.perform_checkout(params)
        checkout = WepayCheckoutRecord.create(params.merge({ checkout_id: response['checkout_id'] }))
        raise WepayRails::Exceptions::InitializeCheckoutError.new("A problem occurred while trying to checkout. Wepay didn't send us back a checkout uri. Response was: #{response.inspect}, Params were: #{params}, Token was: #{wepay_access_token}") unless response && response.has_key?('checkout_uri')
        redirect_to response['checkout_uri'] and return
      end
    end
  end
end
