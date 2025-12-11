defmodule Noface.TestFixtures do
  @moduledoc false

  def build_issue(id, attrs \\ %{}) do
    base = %{id: id, status: :pending}
    attrs = Map.new(attrs)
    struct!(Noface.Core.State.IssueState, Map.merge(base, attrs))
  end

  def with_temp_vault(fun) do
    tmp = Path.join(System.tmp_dir!(), "noface-vault-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "note.md"), "# note\nbody\n")

    try do
      fun.(tmp)
    after
      File.rm_rf(tmp)
    end
  end
end
