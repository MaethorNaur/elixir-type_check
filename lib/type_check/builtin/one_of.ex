defmodule TypeCheck.Builtin.OneOf do
  defstruct [:choices]

  defimpl TypeCheck.Protocols.ToCheck do
    def to_check(x = %{choices: choices}, param) do
      snippets =
        choices
        |> Enum.flat_map(fn choice ->
          choice_check = TypeCheck.Protocols.ToCheck.to_check(choice, param)
          quote location: :keep do
            [
              {:error, problem} <- (unquote(choice_check)),
              problems = [problem | problems],
            ]
          end
        end)

        quote location: :keep do
          problems = []
          with unquote_splicing(snippets) do
            {:error, {unquote(Macro.escape(x)), :all_failed, %{problems: Enum.reverse(problems)}, unquote(param)}}
          else
            {:ok, bindings} ->
              {:ok, bindings}
          end
        end
    end
  end

    defimpl TypeCheck.Protocols.Inspect do
      def inspect(one_of, opts) do
        Inspect.Algebra.container_doc("", one_of.choices, "", opts, &TypeCheck.Protocols.Inspect.inspect/2, separator: " |", break: :maybe)
      end
    end

    if Code.ensure_loaded?(StreamData) do
      defimpl TypeCheck.Protocols.ToStreamData do
        def to_gen(s) do
          s.choices
          |> Enum.map(&TypeCheck.Protocols.ToStreamData.to_gen/1)
          |> StreamData.one_of()
        end
      end
    end
end