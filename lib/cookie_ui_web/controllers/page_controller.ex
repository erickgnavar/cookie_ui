defmodule CookieUIWeb.PageController do
  use CookieUIWeb, :controller

  def home(conn, _params) do
    # The home page is often custom made,
    # so skip the default app layout.
    render(conn, :home, layout: false)
  end

  def download(conn, %{"file" => file}) do
    path = Path.join([:code.priv_dir(:cookie_ui), file])
    send_download(conn, {:file, path})
  end
end
