defmodule InterfaceWeb.Router do
  use InterfaceWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", InterfaceWeb do
    pipe_through :api

    get "/os", InterfaceController, :os
  end
end
