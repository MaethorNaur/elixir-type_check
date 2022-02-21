defmodule TypeCheck.Internals.PreExpander do
  @moduledoc false
  # Rewrites a typecheck-AST
  # to replace all Kernel.SpecialForms
  # with alternatives that are not 'special'
  # that e.g. are function calls to functions in `TypeCheck.Builtin`.
  def rewrite(ast, env, options) do
    builtin_imports = env.functions[TypeCheck.Builtin] || []
    ast
    |> Macro.expand(env)
    |> TypeCheck.Internals.Overrides.rewrite_if_override(Map.get(options, :overrides, []), env)
    |> case do
      ast = {:lazy_explicit, meta, args}  ->
        if {:lazy_explicit, 3} in builtin_imports do
          ast
        else
          {:lazy_explicit, meta, Enum.map(args, &rewrite(&1, env, options))}
        end

      ast = {:literal, meta, [value]} ->
        # Do not expand internals of `literal`.
        # Even if it contains fancy syntax
        # like ranges
        if {:literal, 1} in builtin_imports do
          ast
        else
          {:literal, meta, [rewrite(value, env, options)]}
        end
      ast = {:tuple, meta, [value]} ->
        if {:tuple, 1} in builtin_imports do
          ast
        else
          {:tuple, meta, [rewrite(value, env, options)]}
        end

      {list_taking_fun, meta, [arg]} when is_list(arg) and list_taking_fun in [:fixed_list, :fixed_tuple, :one_of] ->
        if {list_taking_fun, 1} in builtin_imports do
            rewritten_arg = arg
            |> Enum.map(&rewrite(&1, env, options))

          quote generated: true, location: :keep do
            TypeCheck.Builtin.unquote(list_taking_fun)(unquote(rewritten_arg))
          end

        else
          {list_taking_fun, meta, [rewrite(arg, env, options)]}
        end

      ast = {:impl, meta, [module]} ->
         # Do not expand arguments to `impl/1` further
         if {:impl, 1} in builtin_imports do
           ast
         else
           {:impl, meta, [rewrite(module, env, options)]}
         end


      ast = {:&, _, _args} ->
        # Do not expand inside captures
        ast

      x when is_integer(x) or is_float(x) or is_atom(x) or is_bitstring(x) ->
        quote generated: true, location: :keep do
          TypeCheck.Builtin.literal(unquote(x))
        end

      [{:->, _, args}] ->
        case args do
          [[{:"...", _, module}], return_type] when is_atom(module) ->
            quote generated: true, location: :keep do
              TypeCheck.Builtin.function(unquote(rewrite(return_type, env, options)))
            end
          [param_types, return_type] ->
            rewritten_params =
              param_types
              |> Enum.map(&rewrite(&1, env, options))
            quote generated: true, location: :keep do
              TypeCheck.Builtin.function(unquote(rewritten_params), unquote(rewrite(return_type, env, options)))
            end
        end

      list when is_list(list) ->
           case list do
             [] ->
               quote generated: true, location: :keep do
                 TypeCheck.Builtin.literal(unquote([]))
               end
             [{:..., _, _}] ->
               quote generated: true, location: :keep do
                 TypeCheck.Builtin.nonempty_list()
               end

             [element_type] ->
               rewritten_element_type = rewrite(element_type, env, options)
               quote generated: true, location: :keep do
                 TypeCheck.Builtin.list(unquote(rewritten_element_type))
               end
             [element_type, {:..., _, _}] ->
               rewritten_element_type = rewrite(element_type, env, options)
               quote generated: true, location: :keep do
                 TypeCheck.Builtin.nonempty_list(unquote(rewritten_element_type))
               end
             other ->
               raise TypeCheck.CompileError, """
               TypeCheck does not support the list literal `#{Macro.to_string(other)}`
               Currently supported are:
               - [] -> empty list
               - [type] -> list(type)
               - [...] -> nonempty_list()
               - [type, ...] -> nonempty_list(type)
               """
           end
      bitstring = {:<<>>, _, args} ->
           case args do
             [] ->
               # Empty bitstring
               quote generated: true, location: :keep do
                 TypeCheck.Builtin.literal(unquote(<<>>))
               end
             [{:"::", _, [{:_, _, _}, size]}] when is_integer(size) ->
               # <<_ :: size >>
               quote generated: true, location: :keep do
                 TypeCheck.Builtin.sized_bitstring(unquote(size), nil)
               end
             [{:"::", _, [{:_, _, _}, {:*, _, [{:_, _, _}, unit]}]}] when is_integer(unit) ->
               quote generated: true, location: :keep do
                 TypeCheck.Builtin.sized_bitstring(0, unquote(unit))
               end
            [
              {:"::", _, [{:_, _, _}, size]},
              {:"::", _, [{:_, _, _}, {:*, _, [{:_, _, _}, unit]}]}
            ] ->
               quote generated: true, location: :keep do
                 TypeCheck.Builtin.sized_bitstring(unquote(size), unquote(unit))
               end
             _other ->
               raise TypeCheck.CompileError, """
               TypeCheck does not support the bitstring literal `#{Macro.to_string(bitstring)}`
               Currently supported are:
               - <<>> -> empty bitstring
               - <<_ :: size >> -> a bitstring of exactly `size` bytes long
               - <<_ :: _ * unit >> -> a bitstring whose length is divisible by `unit`.
               - <<_ :: size, _ * unit >> -> a bitstring whose (length - `size`) is divisible by `unit`.
               """
           end

      {:|, _, [lhs, rhs]} ->
        quote generated: true, location: :keep do
          TypeCheck.Builtin.one_of(unquote(rewrite(lhs, env, options)), unquote(rewrite(rhs, env, options)))
        end

      ast = {:%{}, _, fields} ->
        rewrite_map_or_struct(fields, ast, env, options)

      {:%, _, [struct_name, {:%{}, _, fields}]} ->
        rewrite_struct(struct_name, fields, env, options)

      {:"::", _, [{name, _, atom}, type_ast]} when is_atom(atom) ->
        quote generated: true, location: :keep do
          TypeCheck.Builtin.named_type(unquote(name), unquote(rewrite(type_ast, env, options)))
        end

      ast = {:when, _, [_type, list]} when is_list(list) ->
        raise TypeCheck.CompileError, """
        Unsupported `when` with keyword arguments in the type description `#{Macro.to_string(ast)}`

        TypeCheck currently does not allow the `function(foo, bar) :: foo | bar when foo: some_type(), bar: other_type()` syntax.
        Instead, define `foo` and `bar` as separate types and refer to those definitions.

        For instance:

        ```
        type foo :: some_type()
        type bar :: other_type()
        spec function(foo, bar) :: foo | bar
        ```
        """

      {:when, _, [type, guard]} ->
        quote generated: true, location: :keep do
          TypeCheck.Builtin.guarded_by(unquote(rewrite(type, env, options)), unquote(Macro.escape(guard)))
        end

      {:{}, _, elements} ->
        rewrite_tuple(elements, env, options)

      {left, right} ->
        rewrite_tuple([left, right], env, options)

      orig = {variable, meta, atom} when is_atom(atom) ->
        # Ensures we'll get no pesky warnings when zero-arity types
        # are used without parentheses (just like 'normal' types)
        if variable_refers_to_function?(variable, env) do
          {variable, meta, []}
        else
          orig
        end

      {other_fun, meta, args} when is_list(args) ->
        # Make sure arguments of any function are expanded
        {other_fun, meta, Enum.map(args, &rewrite(&1, env, options))}

      other ->
        # Fallback
        other
    end
  end

  defp variable_refers_to_function?(name, env) do
    definitions =
      env.functions
      |> Enum.flat_map(fn {_module, definitions} -> definitions end)

    {name, 0} in definitions
  end

  defp rewrite_tuple(tuple_elements, env, options) do
    rewritten_elements =
      tuple_elements
      |> Enum.map(&rewrite(&1, env, options))

    quote generated: true, location: :keep do
      TypeCheck.Builtin.fixed_tuple(unquote(rewritten_elements))
    end
  end

  defp rewrite_map_or_struct(map_fields, orig_ast, env, options) do
    case map_fields[:__struct__] do
      Range ->
        quote generated: true, location: :keep do
          TypeCheck.Builtin.range(unquote(orig_ast))
        end

      nil ->
        res = rewrite_map_fields(map_fields, env, options)
        res[:requireds] |> Macro.to_string() |> IO.puts
        res[:optionals] |> Macro.to_string() |> IO.puts
        # A map with fixed fields
        # Keys are expected to be literal values
        field_types =
          Enum.map(map_fields, fn {key, value_type} -> {key, rewrite(value_type, env, options)} end)

        quote generated: true, location: :keep do
          TypeCheck.Builtin.fixed_map(unquote(field_types))
        end

      _other ->
        # Unhandled already-expanded structs
        # Treat them as literal values
        quote generated: true, location: :keep do
          TypeCheck.Builtin.literal(unquote(orig_ast))
        end
    end
  end

  defp rewrite_map_fields(fields, env, options) do
    Enum.reduce(fields, %{requireds: [], optionals: []}, fn field, acc ->
      case field do
        {literal_key, v} when is_binary(literal_key) or is_integer(literal_key) or is_atom(literal_key) ->
          k = TypeCheck.Builtin.literal(literal_key)
          v = rewrite(v, env, options)
          update_in(acc[:requireds], &[{k, v} | &1])
        {{:required, _, [k]}, v} ->
          k = rewrite(k, env, options)
          v = rewrite(v, env, options)
          update_in(acc[:requireds], &[{k, v} | &1])
        {{:optional, _, [k]}, v} ->
          k = rewrite(k, env, options)
          v = rewrite(v, env, options)
          update_in(acc[:optionals], &[{k, v} | &1])
      end
    end)
  end

  defp rewrite_struct(struct_name, fields, env, options) do
    explicit_field_types =
      fields
      |> Enum.map(fn {key, value_type} -> {key, rewrite(value_type, env, options)} end)
      |> Enum.into(%{})

    expanded_struct_name = Macro.expand(struct_name, env)
    rewritten_struct_name = rewrite(struct_name, env, options)

    # The following is necessary because `%Foo{}` does not equal the type `%{__struct__: Foo}`
    # but  rather `%{__struct__: Foo, some_key: any(), some_other_key: any()}`
    # (using the keys from the `defstruct`)
    default_fields =
      try do
        Macro.struct!(expanded_struct_name, env)
      rescue
        err in [CompileError] ->
          pretty_type = quote do %unquote(struct_name){unquote_splicing(fields)} end
          description = """

          Could not look up default fields for struct type #{Macro.to_string(pretty_type)}.
          This usually means that the type is used in the same module
          as the `defstruct`, but before it.

          Try changing e.g.
          ```
          @type! t() :: %__MODULE__{}
          defstruct [:some, :fields]
          ```

          to:
          ```
          defstruct [:some, :fields]
          @type! t() :: %__MODULE__{}
          ```

          See https://github.com/Qqwy/elixir-type_check/issues/83
          for more information.
          """
          fields =
            err
            |> Map.from_struct()
            |> Map.to_list()
            |> Keyword.replace(:description, description)
          raise CompileError, fields
      end
    default_field_types =
      default_fields
      |> Map.from_struct()
      |> Map.keys()
      |> Enum.map(fn key -> {key, quote do TypeCheck.Builtin.any() end} end)
      |> Enum.into(%{})

    field_types = Map.merge(default_field_types, explicit_field_types) |> Enum.to_list()

    quote generated: true, location: :keep do
      TypeCheck.Builtin.fixed_map(
        [__struct__: unquote(rewritten_struct_name)] ++ unquote(field_types)
      )
    end
  end
end
