defmodule TypeCheck.Builtin.SizedBitstring do
  defstruct [:prefix_size, :unit_size]

  use TypeCheck

  @type! t :: %__MODULE__{prefix_size: non_neg_integer(), unit_size: nil | 1..256}
  @type! problem_tuple ::
    {t(), :no_match, %{}, any()}
  | {t(), :wrong_size, %{}, any()}

  defimpl TypeCheck.Protocols.ToCheck do
    def to_check(s, param) do
      if s.unit_size == nil do
        quote generated: true, location: :keep do
          case unquote(param) do
            x when not is_bitstring(x) ->
              {:error, {unquote(Macro.escape(s)), :no_match, %{}, unquote(param)}}
            x when bit_size(x) != unquote(s.prefix_size) ->
              {:error, {unquote(Macro.escape(s)), :wrong_size, %{}, unquote(param)}}
            _ ->
              {:ok, []}
          end
        end
      else
        quote generated: true, location: :keep do
          case unquote(param) do
            x when not is_bitstring(x) ->
              {:error, {unquote(Macro.escape(s)), :no_match, %{}, unquote(param)}}
            x when bit_size(x) < unquote(s.prefix_size) or rem(bit_size(x) - unquote(s.prefix_size), unquote(s.unit_size)) != 0 ->
              {:error, {unquote(Macro.escape(s)), :wrong_size, %{}, unquote(param)}}
            _ ->
              {:ok, []}
          end
        end
      end
    end
  end

  defimpl TypeCheck.Protocols.Inspect do
    def inspect(s, opts) do
      prefix_size = s.prefix_size |> to_string() |> Inspect.Algebra.color(:number, opts)
      unit_size = s.unit_size |> to_string() |> Inspect.Algebra.color(:number, opts)
      cond do
        s.unit_size == nil ->
          "<<_::#{prefix_size}>>"
        s.prefix_size == 0 ->
          "<<_::_*#{unit_size}>>"
        true ->
          "<<_::#{prefix_size}, _::_*#{unit_size}>>"
      end
      |> Inspect.Algebra.color(:binary, opts)
    end
  end

  if Code.ensure_loaded?(StreamData) do
    defimpl TypeCheck.Protocols.ToStreamData do
      def to_gen(s) do
          if s.unit_size == nil do
            StreamData.bitstring(length: s.prefix_size)
          else
            StreamData.positive_integer()
            |> StreamData.bind(fn int ->
              StreamData.bitstring(length: s.prefix_size + int * s.unit_size)
            end)
          end
      end
    end
  end
end