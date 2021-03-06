module Enginery
  class Generator
    
    include Helpers
    attr_reader :boot_file, :dst_root, :setups

    def initialize dst_root, setups
      @dst_root, @setups = dst_root, setups
    end

    def generate_project name
      name = name.to_s

      if name.empty?
        name = '.'
      else
        name =~ /\.\.|\// && fail('Project name can not contain "/" nor ".."')
        @dst_root, @dst_path_map = File.join(@dst_root, name, ''), nil
      end

      Dir[dst_path(:root, '*')].any? && fail('"%s" should be a empty folder' % dst_path.root)

      o
      o '=== Generating "%s" project ===' % name

      folders, files = Dir[src_path(:base, '**/{*,.[a-z]*}')].partition do |entry|
        File.directory?(entry)
      end

      FileUtils.mkdir_p dst_path.root
      o "#{name}/"
      folders.each do |folder|
        path = unrootify(folder, src_path.base)
        o "  D  #{path}/"
        FileUtils.mkdir_p dst_path(:root, path)
      end

      files.reject {|f| File.basename(f) == '.gitkeep'}.each do |file|
        path = unrootify(file, src_path.base)
        o "  F  #{path}"
        FileUtils.cp file, dst_path(:root, path)
      end

      Configurator.new dst_root, setups do
        update_gemfile
        update_rakefile
        update_boot_rb
        update_config_yml
        update_database_rb
      end
    end

    def generate_controller name

      name.nil? || name.empty? && fail("Please provide controller name via second argument")
      before, ctrl_name, after = namespace_to_source_code(name)

      source_code, i = [], INDENT * before.size
      before.each {|s| source_code << s}
      source_code << "#{i}class #{ctrl_name} < E"
      source_code << "#{i + INDENT}# controller-wide setups"

      if route = setups[:route]
        source_code << "#{i + INDENT}map '#{route}'"
      end
      if engine = setups[:engine]
        source_code << "#{i + INDENT}engine :#{engine}"
        Configurator.new(dst_root, engine: engine).update_gemfile
      end
      if format = setups[:format]
        source_code << "#{i + INDENT}format '#{format}'"
      end
      source_code << INDENT
      
      source_code << "#{i}end"
      after.each  {|s| source_code << s}
      
      path = dst_path(:controllers, class_to_route(name))
      File.exists?(path) && fail("#{name} controller already exists")
      o
      o '=== Generating "%s" controller ===' % name
      o '***   Creating "%s/" ***' % unrootify(path)
      FileUtils.mkdir_p(path)
      file = path + '_controller.rb'
      
      write_file file, source_code.join("\n")
      output_source_code source_code
    end

    def generate_route ctrl_name, name

      action_file, action = valid_action?(ctrl_name, name)

      File.exists?(action_file) && fail("#{name} action/route already exists")

      before, ctrl_name, after = namespace_to_source_code(ctrl_name, false)

      source_code, i = [], '  ' * before.size
      before.each {|s| source_code << s}
      source_code << "#{i}class #{ctrl_name}"
      source_code << "#{i + INDENT}# action-specific setups"
      source_code << ''

      if format = setups[:format]
        source_code << "#{i + INDENT}format_for :#{action}, '#{format}'"
      end
      if setups.any?
        source_code << "#{i + INDENT}before :#{action} do"
        if engine = setups[:engine]
          source_code << "#{i + INDENT*2}engine :#{engine}"
          Configurator.new(dst_root, engine: engine).update_gemfile
        end
        source_code << "#{i + INDENT}end"
        source_code << ""
      end

      source_code << (i + INDENT + "def #{action}")
      action_source_code = ["render"]
      if block_given?
        action_source_code = yield
        action_source_code.is_a?(Array) || action_source_code = [action_source_code]
      end
      action_source_code.each do |line|
        source_code << (i + INDENT*2 + line.to_s)
      end
      source_code << (i + INDENT + "end")
      source_code << ''

      source_code << "#{i}end"
      after.each  {|s| source_code << s}

      o
      o '=== Generating "%s" route ===' % name
      
      write_file action_file, source_code.join("\n")
      output_source_code source_code
    end

    def generate_view ctrl_name, name

      action_file, action = valid_action?(ctrl_name, name)
      _, ctrl = valid_controller?(ctrl_name)

      App.boot!
      ctrl_instance = ctrl.new
      ctrl_instance.respond_to?(action.to_sym) ||
        fail("#{action} action does not exists. Please create it first")
      
      action_name, request_method = deRESTify_action(action)
      ctrl_instance.action_setup  = ctrl.action_setup[action_name][request_method]
      ctrl_instance.call_setups!
      path = File.join(ctrl_instance.view_path?, ctrl_instance.view_prefix?)

      o
      o '=== Generating "%s" view ===' % name
      if File.exists?(path)
        File.directory?(path) || fail("#{unrootify path} should be a directory")
      else
        o '***   Creating "%s/" ***' % unrootify(path)
        FileUtils.mkdir_p(path)
      end
      file = File.join(path, action + ctrl_instance.engine_ext?)
      o '***   Touching "%s" ***' % unrootify(file)
      FileUtils.touch file
    end

    def generate_model name

      name.nil? || name.empty? && fail("Please provide model name via second argument")
      before, model_name, after = namespace_to_source_code(name)
      
      superclass, insertions = '', []
      if orm = setups[:orm] || Cfg[:orm]
        Configurator.new(dst_root, orm: orm).update_gemfile
        orm =~ /\Aa/i && superclass = ' < ActiveRecord::Base'
        orm =~ /\As/i && superclass = ' < Sequel::Model'
        if orm =~ /\Ad/i
          insertions << 'include DataMapper::Resource'
          insertions << ''
          insertions << 'property :id, Serial'
        end
      end
      insertions << ''

      source_code, i = [], INDENT * before.size
      before.each {|s| source_code << s}
      source_code << "#{i}class #{model_name + superclass}"

      insertions.each do |line|
        source_code << (i + INDENT + line.to_s)
      end

      source_code << "#{i}end"
      after.each  {|s| source_code << s}
      source_code = source_code.join("\n")
      
      path = dst_path(:models, class_to_route(name))
      File.exists?(path) && fail("#{name} model already exists")
      
      o
      o '=== Generating "%s" model ===' % name
      dir = File.dirname(path)
      if File.exists?(dir)
        File.directory?(dir) || fail("#{unrootify dir} should be a directory")
      else
        o '***   Creating "%s/" ***' % unrootify(dir)
        FileUtils.mkdir_p(dir)
      end
      
      write_file path + '.rb', source_code
      output_source_code source_code.split("\n")
    end

    def generate_spec ctrl_name, name

      context = {}
      _, context[:controller] = valid_controller?(ctrl_name)
      _, context[:action] = valid_action?(ctrl_name, name)
      context[:spec] = [ctrl_name, context[:action]]*'#'

      o
      o '=== Generating "%s#%s" spec ===' % [ctrl_name, name]
      path = dst_path(:specs, class_to_route(ctrl_name), '/')
      if File.exists?(path)
        File.directory?(path) || fail("#{path} should be a directory")
      else
        o '***   Creating "%s" ***' % unrootify(path)
        FileUtils.mkdir_p(path)
      end

      file = path + context[:action] + '_spec.rb'
      File.exists?(file) && fail('%s already exists' % unrootify(file))
      
      test_framework = setups[:test_framework] || DEFAULT_TEST_FRAMEWORK
      engine = Tenjin::Engine.new(path: [src_path.specfiles], cache: false)
      source_code = engine.render(test_framework.to_s + '.erb', context)

      write_file file, source_code
      output_source_code source_code.split("\n")
    end

  end
end
