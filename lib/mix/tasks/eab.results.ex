defmodule Mix.Tasks.Eab.Results do
  use Mix.Task
  @shortdoc "Build, check, add or preview public run series"
  @moduledoc """
  mix eab.results build
  mix eab.results check
  mix eab.results add /path/to/run.json [--model-label NAME] [--quantization QUANT]
    [--size-gb SIZE] [--resources FILE] [--evidence-url URL] [--note TEXT]
  mix eab.results serve [--port 4173]
  """
  @switches [
    model_label: :string,
    quantization: :string,
    size_gb: :string,
    resources: :string,
    evidence_url: :string,
    note: :string,
    port: :integer
  ]

  @impl true
  def run(args) do
    Mix.Task.run("compile")
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("Invalid options: #{inspect(invalid)}")

    case positional do
      ["add", path] ->
        export_opts = Keyword.drop(opts, [:size_gb, :port, :resources])

        export_opts =
          if opts[:size_gb],
            do: Keyword.put(export_opts, :size_bytes, size!(opts[:size_gb])),
            else: export_opts

        export_opts =
          if opts[:resources],
            do: Keyword.put(export_opts, :resources, Eab.Results.read!(opts[:resources])),
            else: export_opts

        status = Eab.Results.publish!(Eab.Results.read!(path), export_opts)

        Mix.shell().info(
          if(status == :added,
            do: "Added to its run series on the results page",
            else: "Already added; rebuilt results page"
          )
        )

      ["check"] ->
        Mix.shell().info("Validated #{length(Eab.Results.load!())} run series")

      ["build"] ->
        build()

      ["serve"] ->
        directory = build()
        port = opts[:port] || 4173
        unless port in 1..65535, do: Mix.raise("Invalid preview port")
        {:ok, _} = Application.ensure_all_started(:bandit)

        {:ok, _} =
          Bandit.start_link(
            plug: {Eab.Results.Preview, directory},
            ip: {127, 0, 0, 1},
            port: port
          )

        Mix.shell().info("Results preview: http://127.0.0.1:#{port}")
        Process.sleep(:infinity)

      _ ->
        Mix.raise(@moduledoc)
    end
  rescue
    error in [ArgumentError, File.Error, Jason.DecodeError] -> Mix.raise(Exception.message(error))
  end

  defp build do
    records = Eab.Results.load!()
    directory = Eab.Results.build!(records)
    Mix.shell().info("Built #{directory}/index.html (#{length(records)} run series)")
    directory
  end

  defp size!(text) do
    case Float.parse(text) do
      {n, ""} when n > 0 -> round(n * 1_000_000_000)
      _ -> Mix.raise("--size-gb must be a positive number")
    end
  end
end
