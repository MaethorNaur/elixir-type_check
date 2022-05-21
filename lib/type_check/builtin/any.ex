defmodule TypeCheck.Builtin.Any do
  defstruct []

  use TypeCheck
  @opaque! t :: %TypeCheck.Builtin.Any{}
  @type! problem_tuple :: none()

  defimpl TypeCheck.Protocols.ToCheck do
    def to_check(_, param) do
      quote generated: :true, location: :keep do
        {:ok, [], unquote(param)}
      end
    end

    def needs_slow_check?(_), do: false
    def to_check_slow(t, param), do: to_check(t, param)
  end

  defimpl TypeCheck.Protocols.Inspect do
    def inspect(_, opts) do
      "any()"
      |> Inspect.Algebra.color(:builtin_type, opts)
    end
  end

  if Code.ensure_loaded?(StreamData) do
    defimpl TypeCheck.Protocols.ToStreamData do
      def to_gen(_s) do
        StreamData.term()
        |> StreamData.scale(fn size -> trunc(:math.log(size + 1)) end) # Usually we don't need that large terms for an  'any', as no checks will be performed on it anyway.
      end
    end
  end
end
