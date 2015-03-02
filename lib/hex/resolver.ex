defmodule Hex.Resolver do
  alias Hex.Registry

  import Hex.Mix, only: [version_match?: 2]

  require Record
  Record.defrecordp :info, [:top_level, :backtrack_agent]
  Record.defrecordp :state, [:activated, :pending, :optional]
  Record.defrecordp :request, [:app, :name, :req, :parent]
  Record.defrecordp :active, [:app, :name, :version, :state, :parents, :possibles]

  def resolve(requests, top_level, locked) do
    {:ok, agent_pid} = Agent.start_link(fn -> [] end)
    info = info(top_level: top_level, backtrack_agent: agent_pid)

    {activated, pending, optional} =
      Enum.reduce(locked, {HashDict.new, [], HashDict.new}, &locked(&1, &2, info))

    req_requests =
      Enum.map(requests, fn {name, app, req, from} ->
        req = compile_requirement(req, name)
        request(name: name, app: app, req: req, parent: {from, req})
      end)
      |> Enum.uniq

    pending = pending ++ req_requests
    if activated = do_resolve(activated, pending, optional, info) do
      Agent.stop(agent_pid)
      {:ok, activated}
    else
      messages = Agent.get(agent_pid, & &1)
      Agent.stop(agent_pid)
      {:error, Enum.join(messages, "\n\n")}
    end
  end

  defp locked({name, app, version}, {activated, pending, optional}, info) do
    # Make sure to add children of locked dependencies, they may be missing
    # from the lock for multiple reasons

    {new_pending, new_optional} = get_deps(name, version, info)
    pending = pending ++ new_pending
    optional = merge_optional(optional, new_optional)

    {:ok, req} = Version.parse_requirement(version)
    active = active(name: name, app: app, version: version, parents: [{"mix.lock", req}], possibles: [])
    activated = Dict.put(activated, name, active)

    {activated, pending, optional}
  end

  defp do_resolve(activated, [], _optional, _info) do
    Enum.map(activated, fn {name, active(app: app, version: version)} ->
      {name, app, version}
    end) |> Enum.reverse
  end

  defp do_resolve(activated, [request(app: app, name: name, req: req, parent: parent) = request|pending], optional, info) do
    case activated[name] do
      active(version: version, possibles: possibles, parents: parents) = active ->
        possibles = Enum.filter(possibles, &version_match?(&1, req))
        active = active(active, possibles: possibles, parents: [parent|parents])

        if version_match?(version, req) do
          activated = Dict.put(activated, name, active)
          do_resolve(activated, pending, optional, info)
        else
          backtrack_message(name, version, [parent|parents], info)
          backtrack(active, activated, info)
        end

      nil ->
        {opts, optional} = Dict.pop(optional, name)
        opts = opts || []
        requests = [request|opts]

        case get_versions(name, requests) do
          {:error, request(parent: parent)} ->
            backtrack_message(name, nil, [parent|opts], info)
            backtrack(activated[parent], activated, info)

          {:ok, [version|possibles]} ->
            {new_pending, new_optional} = get_deps(name, version, info)
            new_pending = pending ++ new_pending
            new_optional = merge_optional(optional, new_optional)

            state = state(activated: activated, pending: pending, optional: optional)
            new_active = active(app: app, name: name, version: version, state: state,
                                possibles: possibles, parents: [parent])
            activated = Dict.put(activated, name, new_active)

            do_resolve(activated, new_pending, new_optional, info)
        end
    end
  end

  defp backtrack(nil, _activated, _info) do
    nil
  end

  defp backtrack(active(name: name, possibles: possibles, parents: parents, state: state) = active, activated, info) do
    case possibles do
      [] ->
        Enum.find_value(parents, fn
          {{parent, _version}, _req} when not parent in ~w(mix_exs mix_lock)a ->
            backtrack(activated[parent], activated, info)
          _ ->
            nil
        end)

      [version|possibles] ->
        state(activated: activated, pending: pending, optional: optional) = state

        active = active(active, possibles: possibles, version: version)
        {new_pending, new_optional} = get_deps(name, version, info)
        pending = pending ++ new_pending
        optional = merge_optional(optional, new_optional)

        activated = Dict.put(activated, name, active)
        do_resolve(activated, pending, optional, info)
    end
  end

  defp get_versions(package, requests) do
    if versions = Registry.get_versions(package) do
      try do
        versions =
          Enum.reduce(requests, versions, fn request(req: req) = request, versions ->
            versions = Enum.filter(versions, &version_match?(&1, req))
            if versions == [] do
              throw request
            else
              versions
            end
          end)

        {:ok, Enum.reverse(versions)}
      catch
        :throw, request ->
          {:error, request}
      end

    else
      Mix.raise "Unable to find package #{package} in registry"
    end
  end

  defp get_deps(package, version, info(top_level: top_level)) do
    if deps = Registry.get_deps(package, version) do
      parents = down_to(top_level, String.to_atom(package))

      {reqs, opts} =
        Enum.reduce(deps, {[], []}, fn {name, app, req, optional}, {reqs, opts} ->
          req = compile_requirement(req, name)
          parent = {{package, version}, req}
          request = request(app: app, name: name, req: req, parent: parent)

          cond do
            was_overriden?(parents, String.to_atom(app)) ->
              {reqs, opts}
            optional ->
              {reqs, [request|opts]}
            true ->
              {[request|reqs], opts}
          end
        end)

        {Enum.reverse(reqs), Enum.reverse(opts)}
    else
      Mix.raise "Unable to find package version #{package} v#{version} in registry"
    end
  end

  defp was_overriden?(parents, app) do
    Enum.any?(parents, fn parent ->
      app == parent.app && parent.opts[:override]
    end)
  end

  defp down_to(level, parent) do
    children =
      Enum.flat_map level, fn dep ->
        down_to(dep.deps, parent)
      end

    cond do
      children != [] ->
        level ++ children
      parent in Enum.map(level, & &1.app) ->
        level
      true ->
        []
    end
  end

  defp merge_optional(optional, new_optional) do
    new_optional =
      Enum.map(new_optional, fn request(name: name) = request ->
        {name, [request]}
      end)
    Dict.merge(optional, new_optional, fn _, v1, v2 -> v1 ++ v2 end)
  end

  defp compile_requirement(nil, _package) do
    nil
  end

  defp compile_requirement(req, package) when is_binary(req) do
    case Version.parse_requirement(req) do
      {:ok, req} ->
        req
      :error ->
        Mix.raise "Invalid requirement #{inspect req} defined for package #{package}"
    end
  end

  defp compile_requirement(req, package) do
    Mix.raise "Invalid requirement #{inspect req} defined for package #{package}"
  end

  defp backtrack_message(name, version, parents, info(backtrack_agent: agent)) do
    string = [
      "Looking up alternatives for conflicting requirements on #{name}",
      if(version, do: "  Activated version: #{version}"),
      "  " <> Enum.map_join(parents, "\n  ", &parent/1)]
      |> Enum.filter(& &1)
      |> Enum.join("\n")

    Agent.cast(agent, &[string|&1])
  end

  defp parent({path, req}) when is_binary(path),
    do: "From #{path} : #{requirement(req)}"
  defp parent({{parent, version}, req}),
    do: "From #{parent} v#{version} : #{requirement(req)}"

  defp requirement(nil), do: ""
  defp requirement(req), do: req.source
end
