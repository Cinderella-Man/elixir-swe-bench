# Prints, per case, the current runtime image and the named outcomes of its qualification receipt.
out =
  for id <- Eab.Inventory.all(), into: %{} do
    runtime = Eab.Store.read("runtimes/#{id}.json")
    identity = runtime && Eab.Grader.qualification_identity(id, runtime)
    receipt = identity && Eab.Store.read("qualifications/#{Eab.Cache.key(identity)}.json")
    {id, %{"image" => runtime && runtime["image"], "toolchain" => runtime && runtime["toolchain_image"], "receipt" => receipt}}
  end
IO.puts("JSON_START" <> Jason.encode!(out) <> "JSON_END")
