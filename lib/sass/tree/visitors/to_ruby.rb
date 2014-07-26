class Sass::Tree::Visitors::ToRuby < Sass::Tree::Visitors::Base
  class << self
    def visit(root, environment = nil)
      new(environment).send(:visit, root)
    end
  end

  def initialize(environment)
    @imports = {}
    @environment = environment
    @environment_var = "_s_env"
  end

  def visit_children(parent)
    # Make sure the environment knows about all definitions defined at this
    # scope. That way nested references to those definitions will refer to the
    # correct referents.
    parent.children.each do |child|
      case child
      when Sass::Tree::VariableNode
        @environment.declare_var(child.name) unless child.global
      when Sass::Tree::FunctionNode
        @environment.declare_fn(child.name)
      end
    end

    super.join("\n")
  end

  def with_parent(name)
    old_env, @environment = @environment, Sass::Environment.new(@environment)
    old_parent_var, @parent_var = @parent_var, name
    old_env_var = @environment.unique_ident(:old_env)
    "#{old_env_var}, #{@environment_var} = #{@environment_var}, ::Sass::Environment.new(#{@environment_var})\n" +
      yield + "\n" +
      "#{@environment_var} = #{old_env_var}"
  ensure
    @parent_var = old_parent_var
    @environment = old_env
  end

  def visit_root(node)
    root_var = "_s_root"
    "#{@environment_var} = ::Sass::Environment.new\n" +
      "#{root_var} = ::Sass::Tree::RootNode.new('')\n" +
      with_parent(root_var) {yield} + "\n" + root_var
  end

  def visit_comment(node)
    return '' if node.invisible?
    "#{@parent_var} << ::Sass::Tree::CommentNode.resolved(" +
      "#{interp_no_strip(node.value)}, #{node.type.inspect})"
  end

  def visit_function(node)
    name = @environment.declare_fn(node.name)
    with_parent(nil) do
      ruby = "#{name} = lambda do |" + node.args.map do |(arg, default)|
        arg_name = @environment.local_var_ident(arg.name)
        next arg_name unless default
        "#{arg_name} = #{default.to_ruby(@environment)}"
      end.join(', ')

      # TODO: support splat and named args

      ruby + "|\n#{yield}\nend"
    end
  end

  def visit_import(node)
    if (path = node.css_import?)
      return "#{@parent_var} << Sass::Tree::CssImportNode.resolved(#{"url(#{path})".dump})"
    end

    # TODO: Handle import loops.
    # Longer-term TODO: Under --watch, only re-eval these methods when the files
    # change.
    file = node.imported_file
    filename = file.options[:filename]
    ruby = ''
    unless (method_name = @imports[filename])
      method_name = @imports[filename] = @environment.unique_ident("import_#{filename}")
      root = file.to_tree
      Sass::Tree::Visitors::CheckNesting.visit(root)
      ruby = "def #{method_name}(#{@parent_var}, #{@environment_var})\n" +
        root.children.map {|c| visit(c)}.join("\n") + "\nend\n"
    end

    ruby + "#{method_name}(#{@parent_var}, #{@environment_var})"
  end

  def visit_prop(node)
    prop_var = @environment.unique_ident(:prop)
    ruby = "#{@parent_var} << #{prop_var} = ::Sass::Tree::PropNode.resolved(#{interp(node.name)}, " +
      "#{node.value.to_ruby(@environment)}.to_s)"
    with_parent(prop_var) {ruby + yield}
  end

  def visit_return(node)
    "return #{node.expr.to_ruby(@environment)}"
  end

  def visit_rule(node)
    parser_var = @environment.unique_ident(:parser)
    selector_var = @environment.unique_ident(:selector)
    ruby = "#{parser_var} = ::Sass::SCSS::StaticParser.new(#{interp(node.rule)}, '', nil, 0)\n"
    rule_var = @environment.unique_ident(:rule)
    ruby << "#{@parent_var} << #{rule_var} = ::Sass::Tree::RuleNode.resolved(" +
      "#{parser_var}.parse_selector.resolve_parent_refs(#{@environment_var}.selector))\n"
    with_parent(rule_var) do
      ruby << "#{@environment_var}.selector = #{rule_var}.resolved_rules\n"
      ruby + yield
    end
  end

  def visit_variable(node)
    old_var_var = @environment.var_variable(node.name)
    var_var = old_var_var ||
      if node.global
        @environment.declare_global_var(node.name)
      else
        @environment.declare_var(node.name)
      end

    ruby = "#{var_var} = #{node.expr.to_ruby(@environment)}"
    ruby << "if #{var_var}.null?" if node.guarded && old_var_var
    ruby
  end

  def interp(script)
    script.map do |e|
      next e.dump if e.is_a?(String)
      "#{e.to_ruby(@environment)}.to_s"
    end.join(" + ")
  end
end
