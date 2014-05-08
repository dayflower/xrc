require "active_support/core_ext/string/indent"
require "base64"

module Xrc
  class Client
    DEFAULT_PORT = 5222

    SASL_NAMESPACE = "urn:ietf:params:xml:ns:xmpp-sasl"

    TLS_NAMESPACE = "urn:ietf:params:xml:ns:xmpp-tls"

    attr_reader :options

    def initialize(options = {})
      @options = options
    end

    def run
      connect
      start
      wait
    end

    # Dirty
    def receive(element)
      case
      when element.prefix == "stream" && element.name == "features"
        element.each do |feature|
          case
          when feature.name == "starttls" && feature.namespace == TLS_NAMESPACE
            start_tls
          when feature.name == "mechanisms" && feature.namespace == SASL_NAMESPACE
            feature.each_element("mechanism") do |mechanism|
              mechanisms << mechanism.text
            end
            on_mechanisms_received
          else
            features[feature.name] = feature.namespace
          end
        end
      when element.name == "proceed" && element.namespace == TLS_NAMESPACE
        change_socket
      when element.name == "success" && element.namespace == SASL_NAMESPACE
        on_authentication_succeeded
      when element.name == "failure" && element.namespace == SASL_NAMESPACE
        on_authentication_failed
      end
    end

    log :receive do |element|
      "Received:\n" + "#{REXML::Formatters::Pretty.new(2).write(element, '')}".indent(2)
    end

    private

    def on_authentication_succeeded
      start
    end

    def on_authentication_failed
      raise NotImplementedError
    end

    def authenticate
      case
      when mechanisms.include?("PLAIN")
        element = REXML::Element.new("auth")
        element.add_namespace(SASL_NAMESPACE)
        element.attributes["mechanism"] = "PLAIN"
        element.text = Base64.strict_encode64(plain_credentials)
        post(element)
      else
        raise NotImplementedError
      end
    end

    def plain_credentials
      "#{jid}\x00#{jid.node}\x00#{password}"
    end

    def on_mechanisms_received
      authenticate if has_password?
    end

    def has_password?
      !!password
    end

    def password
      options[:password]
    end

    def connect
      socket
    end

    log :connect do
      "Connecting to #{domain}:#{port}"
    end

    def start_tls
      element = REXML::Element.new("starttls")
      element.add_namespace("urn:ietf:params:xml:ns:xmpp-tls")
      post(element)
    end

    log :start_tls do
      "Start TLS connection"
    end

    def change_socket
      @socket = tsl_connector.connect
      start
      regenerate_parser
      wait
    end

    log :change_socket do
      "Changing socket to TSL socket"
    end

    def wait
      parser.parse
    end

    def parser
      @parser ||= generate_parser
    end

    def generate_parser
      Parser.new(socket, client: self)
    end

    def regenerate_parser
      @parser = generate_parser
    end

    log :regenerate_parser do
      "Regenerating parser"
    end

    def jid
      @jid ||= Jid.new(options[:jid])
    end

    def port
      options[:port] || DEFAULT_PORT
    end

    def socket
      @socket ||= connector.connect
    end

    def features
      @features ||= {}
    end

    def mechanisms
      @mechanisms ||= []
    end

    def connector
      Connector.new(domain: domain, port: port)
    end

    def tsl_connector
      TslConnector.new(socket: socket)
    end

    def domain
      jid.domain
    end

    def start
      post(start_message)
    end

    log :start do
      "Starting stream"
    end

    def post(element)
      socket << element.to_s
    end

    log :post do |element|
      "Posting:\n" + element.to_s.indent(2)
    end

    # Dirty
    def start_message
      %W[
        <stream:stream
        xmlns:stream="http://etherx.jabber.org/streams"
        xmlns="jabber:client"
        to="#{domain}"
        xml:lang="en"
        version="1.0">
      ].join(" ")
    end
  end
end
