defmodule TypeCheck.SpecTest do
  use ExUnit.Case, async: true

  doctest TypeCheck.Spec

  test "fully qualified function names in type guards should not be required (regression test against #147)" do
    # The following should not raise a compiler error:
    defmodule SpecTest.FQFN.A do
      use TypeCheck

      @type! f :: integer() when is_f(f)

      def is_f(_f), do: true
    end

    defmodule SpecTest.FQFN.B do
      use TypeCheck

      @spec! f() :: SpecTest.FQFN.A.f()
      def f(), do: 1
    end
  end

  test "Using TypeCheck in non-Elixir modules (lower case atoms) is OK (regression test against ##174)" do
    defmodule :my_module_name do
      use TypeCheck

      @type! str :: String.t()

      @spec! hello(str()) :: :ok
      def hello(name) do
        IO.puts("Hello #{name}!")
        :ok
      end
    end
  end
end
