import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/interface start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.

mix_target = Nerves.Runtime.mix_target()
{:ok, hostname} = :inet.gethostname()
port = if mix_target == :host, do: 8080, else: 80

if mix_target == :host do
  config :hello_nerves, dev_routes: true

  # Do not include metadata nor timestamps in development logs
  config :logger, :default_formatter, format: "[$level] $message\n"

  # Set a higher stacktrace during development. Avoid configuring such
  # in production as building large stacktraces may be expensive.
  config :phoenix, :stacktrace_depth, 20

  # Initialize plugs at runtime for faster development compilation
  config :phoenix, :plug_init_mode, :runtime
end

config :logger, level: :info
config :ex_gram, Tesla.Middleware.Logger, level: :debug

config :hello_nerves, InterfaceWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "#{hostname}.local", path: "/"],
  render_errors: [formats: [json: InterfaceWeb.ErrorJSON], layout: false],
  http: [
    port: port,
    http_1_options: [max_header_length: 32768]
  ],
  drainer: [shutdown: 1000],
  code_reloader: false,
  server: true
