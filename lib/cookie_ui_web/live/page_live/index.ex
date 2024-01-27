defmodule CookieUIWeb.PageLive.Index do
  use CookieUIWeb, :live_view

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    form_fields = %{"url" => ""}

    {:ok,
     assign(socket,
       step: :initial,
       stream: "",
       params: %{},
       clone_dir: nil,
       repo_url: nil,
       form: to_form(form_fields),
       download_name: nil,
       cookie_form: to_form(%{})
     )}
  end

  def handle_event("validate", params, socket) do
    case URI.parse(params["url"]) do
      %{host: host, path: path, scheme: scheme}
      when is_nil(host) or is_nil(path) or is_nil(scheme) ->
        # TODO: add error messages
        {:noreply, assign(socket, form: to_form(params))}

      _valid_url ->
        {:noreply, socket}
    end

    {:noreply, socket}
  end

  def handle_event("process", params, socket) do
    case clone_repo(params["url"]) do
      {:ok, output, clone_dir} ->
        json_path = Path.join([clone_dir, "cookiecutter.json"])
        Process.send_after(self(), {:parse_json, json_path}, :timer.seconds(1))

        {:noreply,
         assign(socket,
           stream: output,
           clone_dir: clone_dir,
           repo_url: params["url"],
           step: :cloning
         )}

      {:error, reason} ->
        {:noreply, assign(socket, stream: reason)}
    end
  end

  def clone_repo(git_url) do
    random_path = random_string(10)

    clone_dir = Path.join([System.tmp_dir!(), random_path])
    File.mkdir(clone_dir)

    case System.cmd("git", ["clone", "--progress", git_url, clone_dir, "--depth=1"]) do
      {output, 0} ->
        Logger.info("Git output: #{inspect(output)}")
        {:ok, output, clone_dir}

      error ->
        Logger.error("Git error: #{inspect(error)}")
        {:error, "#{inspect(error)}"}
    end
  end

  @impl true
  def handle_info({:parse_json, path}, socket) do
    Logger.debug("Parsing #{path}")

    with {:ok, content} <- File.read(path),
         {:ok, parsed} <- Jason.decode(content) do
      Process.send_after(self(), {:prepare_form, parsed}, :timer.seconds(1))
      {:noreply, assign(socket, params: parsed, step: :filling)}
    else
      error ->
        Logger.error("There was an error while parsing: #{inspect(error)}")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:prepare_form, parsed_json}, socket) do
    filtered =
      parsed_json
      |> Enum.map(fn {key, value} ->
        if is_list(value) do
          # ignore by now choices options
          # TODO: remove this and generate selects
          {key, hd(value)}
        else
          {key, value}
        end
      end)
      |> Enum.into(%{})

    {:noreply, assign(socket, cookie_form: to_form(filtered))}
  end

  def handle_event("validate2", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("generate", params, socket) do
    random_path = random_string(10)

    config_file_path = Path.join([System.tmp_dir!(), "#{random_path}.yaml"])

    # used to run cookiecutter
    work_dir = Path.join([System.tmp_dir!(), random_string(10)])
    File.mkdir(work_dir)

    File.open(config_file_path, [:write, :utf8], fn file ->
      content = Ymlr.document!(%{"default_context" => params})
      IO.write(file, content)
    end)

    case System.cmd(
           "cookiecutter",
           [
             socket.assigns.repo_url,
             "--no-input",
             "--config-file",
             config_file_path
           ],
           cd: work_dir
         ) do
      {output, 0} ->
        Logger.info("Cookiecutter generation: #{output}")

        # in this directory it should exists only one directory
        generated_dir_name =
          work_dir
          |> File.ls!()
          |> hd()

        generated_dir_path = Path.join([work_dir, generated_dir_name])

        files =
          generated_dir_path
          |> File.ls!()
          |> Enum.map(&String.to_charlist/1)

        zip_filename = Path.join([:code.priv_dir(:cookie_ui), random_string(10)]) <> ".zip"

        {ok, _filename} = :zip.create(zip_filename, files, cwd: generated_dir_path)

        download_name = String.split(zip_filename, "/") |> List.last()

        {:noreply, assign(socket, step: :done, download_name: "/#{download_name}")}

      error ->
        Logger.error("There was an error while generating: #{inspect(error)}")

        {:noreply, socket}
    end
  end

  defp random_string(length) do
    length
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64()
    |> binary_part(0, length)
  end
end
