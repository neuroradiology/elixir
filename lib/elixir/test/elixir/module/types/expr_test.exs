Code.require_file("../../test_helper.exs", __DIR__)

defmodule Module.Types.ExprTest do
  use ExUnit.Case, async: true
  import Module.Types.Expr
  alias Module.Types
  alias Module.Types.Infer

  defmacrop quoted_expr(vars \\ [], body) do
    quote do
      {vars, body} = unquote(Macro.escape(expand_expr(vars, body)))

      body
      |> of_expr(new_stack(), new_context(vars))
      |> lift_result()
    end
  end

  defp expand_expr(vars, expr) do
    fun =
      quote do
        fn unquote(vars) -> unquote(expr) end
      end

    {ast, _env} = :elixir_expand.expand(fun, __ENV__)
    {:fn, _, [{:->, _, [[vars], body]}]} = ast
    {vars, body}
  end

  defp new_context(vars) do
    context = Types.context("types_test.ex", TypesTest, {:test, 0})

    Enum.reduce(vars, context, fn var, context ->
      {_type, context} = Infer.new_var(var, context)
      context
    end)
  end

  defp new_stack() do
    %{
      Types.stack()
      | last_expr: {:foo, [], nil}
    }
  end

  defp lift_result({:ok, type, context}) do
    {:ok, Types.lift_type(type, context)}
  end

  defp lift_result({:error, {Types, reason, location}}) do
    {:error, {reason, location}}
  end

  defmodule :"Elixir.Module.Types.ExprTest.Struct" do
    defstruct foo: :atom, bar: 123, baz: %{}
  end

  test "literal" do
    assert quoted_expr(true) == {:ok, {:atom, true}}
    assert quoted_expr(false) == {:ok, {:atom, false}}
    assert quoted_expr(:foo) == {:ok, {:atom, :foo}}
    assert quoted_expr(0) == {:ok, :integer}
    assert quoted_expr(0.0) == {:ok, :float}
    assert quoted_expr("foo") == {:ok, :binary}
  end

  describe "list" do
    test "proper" do
      assert quoted_expr([]) == {:ok, {:list, :dynamic}}
      assert quoted_expr([123]) == {:ok, {:list, :integer}}
      assert quoted_expr([123, 456]) == {:ok, {:list, :integer}}
      assert quoted_expr([123 | []]) == {:ok, {:list, :integer}}
      assert quoted_expr([123, "foo"]) == {:ok, {:list, {:union, [:integer, :binary]}}}
      assert quoted_expr([123 | ["foo"]]) == {:ok, {:list, {:union, [:integer, :binary]}}}
    end

    test "improper" do
      assert quoted_expr([123 | 456]) == {:ok, {:list, :integer}}
      assert quoted_expr([123, 456 | 789]) == {:ok, {:list, :integer}}
      assert quoted_expr([123 | "foo"]) == {:ok, {:list, {:union, [:integer, :binary]}}}
    end
  end

  test "tuple" do
    assert quoted_expr({}) == {:ok, {:tuple, []}}
    assert quoted_expr({:a}) == {:ok, {:tuple, [{:atom, :a}]}}
    assert quoted_expr({:a, 123}) == {:ok, {:tuple, [{:atom, :a}, :integer]}}
  end

  test "map" do
    assert quoted_expr(%{}) == {:ok, {:map, []}}
    assert quoted_expr(%{a: :b}) == {:ok, {:map, [{{:atom, :a}, {:atom, :b}}]}}
    assert quoted_expr([a], %{123 => a}) == {:ok, {:map, [{:integer, {:var, 0}}]}}

    assert quoted_expr(%{123 => :foo, 456 => :bar}) ==
             {:ok, {:map, [{:integer, {:union, [{:atom, :bar}, {:atom, :foo}]}}]}}
  end

  test "struct" do
    assert quoted_expr(%:"Elixir.Module.Types.ExprTest.Struct"{}) ==
             {:ok,
              {:map,
               [
                 {{:atom, :__struct__}, {:atom, Module.Types.ExprTest.Struct}},
                 {{:atom, :bar}, :integer},
                 {{:atom, :baz}, {:map, []}},
                 {{:atom, :foo}, {:atom, :atom}}
               ]}}

    assert quoted_expr(%:"Elixir.Module.Types.ExprTest.Struct"{foo: 123, bar: :atom}) ==
             {:ok,
              {:map,
               [
                 {{:atom, :__struct__}, {:atom, Module.Types.ExprTest.Struct}},
                 {{:atom, :baz}, {:map, []}},
                 {{:atom, :foo}, :integer},
                 {{:atom, :bar}, {:atom, :atom}}
               ]}}
  end

  describe "binary" do
    test "literal" do
      assert quoted_expr(<<"foo"::binary>>) == {:ok, :binary}
      assert quoted_expr(<<123::integer>>) == {:ok, :binary}
      assert quoted_expr(<<123::utf8>>) == {:ok, :binary}
      assert quoted_expr(<<"foo"::utf8>>) == {:ok, :binary}
    end

    test "variable" do
      assert quoted_expr([foo], <<foo::little>>) == {:ok, :binary}
      assert quoted_expr([foo], <<foo::integer>>) == {:ok, :binary}
      assert quoted_expr([foo], <<foo::integer()>>) == {:ok, :binary}
      assert quoted_expr([foo], <<foo::integer-little>>) == {:ok, :binary}
      assert quoted_expr([foo], <<foo::little-integer>>) == {:ok, :binary}
    end

    test "infer" do
      assert quoted_expr(
               (
                 foo = 0.0
                 <<foo::float>>
               )
             ) == {:ok, :binary}

      assert quoted_expr(
               (
                 foo = 0
                 <<foo::float>>
               )
             ) == {:ok, :binary}

      assert quoted_expr([foo], {<<foo::integer>>, foo}) == {:ok, {:tuple, [:binary, :integer]}}
      assert quoted_expr([foo], {<<foo::binary>>, foo}) == {:ok, {:tuple, [:binary, :binary]}}

      assert quoted_expr([foo], {<<foo::utf8>>, foo}) ==
               {:ok, {:tuple, [:binary, {:union, [:integer, :binary]}]}}

      assert {:error, {{:unable_unify, :integer, :binary, _, _}, _}} =
               quoted_expr(
                 (
                   foo = 0
                   <<foo::binary>>
                 )
               )

      assert {:error, {{:unable_unify, :binary, :integer, _, _}, _}} =
               quoted_expr([foo], <<foo::binary-0, foo::integer>>)
    end
  end

  test "variables" do
    assert quoted_expr([foo], foo) == {:ok, {:var, 0}}
    assert quoted_expr([foo], {foo}) == {:ok, {:tuple, [{:var, 0}]}}
    assert quoted_expr([foo, bar], {foo, bar}) == {:ok, {:tuple, [{:var, 0}, {:var, 1}]}}
  end

  test "pattern match" do
    assert {:error, _} = quoted_expr(:foo = 1)
    assert {:error, _} = quoted_expr(1 = :foo)

    assert quoted_expr(:foo = :foo) == {:ok, {:atom, :foo}}
    assert quoted_expr(1 = 1) == {:ok, :integer}
  end

  test "block" do
    assert quoted_expr(
             (
               a = 1
               a
             )
           ) == {:ok, :integer}

    assert quoted_expr(
             (
               a = :foo
               a
             )
           ) == {:ok, {:atom, :foo}}

    assert {:error, _} =
             quoted_expr(
               (
                 a = 1
                 :foo = a
               )
             )
  end

  describe "case" do
    test "infer pattern" do
      assert quoted_expr(
               [a],
               case a do
                 :foo = b -> :foo = b
               end
             ) == {:ok, :dynamic}

      assert {:error, _} =
               quoted_expr(
                 [a],
                 case a do
                   :foo = b -> :bar = b
                 end
               )
    end

    test "do not leak pattern/guard inference between clauses" do
      assert quoted_expr(
               [a],
               case a do
                 :foo = b -> b
                 :bar = b -> b
               end
             ) == {:ok, :dynamic}

      assert quoted_expr(
               [a],
               case a do
                 b when is_atom(b) -> b
                 b when is_integer(b) -> b
               end
             ) == {:ok, :dynamic}

      assert quoted_expr(
               [a],
               case a do
                 :foo = b -> :foo = b
                 :bar = b -> :bar = b
               end
             ) == {:ok, :dynamic}
    end

    test "do not leak body inference between clauses" do
      assert quoted_expr(
               [a],
               case a do
                 :foo ->
                   b = :foo
                   b

                 :bar ->
                   b = :bar
                   b
               end
             ) == {:ok, :dynamic}

      assert quoted_expr(
               [a, b],
               case a do
                 :foo -> :foo = b
                 :bar -> :bar = b
               end
             ) == {:ok, :dynamic}

      assert quoted_expr(
               [a, b],
               case a do
                 :foo when is_binary(b) -> b <> ""
                 :foo when is_list(b) -> b
               end
             ) == {:ok, :dynamic}
    end
  end

  test "fn" do
    assert quoted_expr(fn :foo = b -> :foo = b end) == {:ok, :dynamic}

    assert {:error, _} = quoted_expr(fn :foo = b -> :bar = b end)
  end

  test "with" do
    assert quoted_expr(
             [a, b],
             with(
               :foo <- a,
               :bar <- b,
               c = :baz,
               do: c
             )
           ) == {:ok, :dynamic}

    assert quoted_expr(
             [a],
             (
               with(a = :baz, do: a)
               a
             )
           ) == {:ok, {:var, 0}}
  end

  test "for" do
    assert quoted_expr(
             [list],
             for(
               foo <- list,
               is_integer(foo),
               do: foo == 123
             )
           ) == {:ok, :dynamic}

    assert quoted_expr(
             [list, bar],
             (
               for(
                 foo <- list,
                 is_integer(bar),
                 do: foo == 123
               )

               bar
             )
           ) == {:ok, {:var, 0}}
  end
end
