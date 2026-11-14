# frozen_string_literal: true

module DocsGuard
  # Answers whether a name the docs write in code (+Engine::Hydrator+,
  # +Store#find_proof+, +BRC29.key_id+) exists in the code loaded into this
  # process.
  #
  # Names resolve by suffix: +Hydrator+ matches every loaded module whose
  # full name ends in +::Hydrator+, because the docs drop whatever prefix
  # the context makes obvious. A method reference passes if any candidate
  # defines it. That is lenient about ambiguity, but strict about the drift
  # the guard exists for: a name that nothing defines.
  #
  # Reflection only: names come from untrusted doc text, so nothing here
  # calls a method by that name.
  class CodeIndex
    # A placeholder for the schema's identity CHECK; the store holds no keys.
    PLACEHOLDER_IDENTITY_HASH = ("\0" * 20).b.freeze

    # Requires every Ruby file under +lib_dir+ and forces the autoloads
    # under each of +namespaces+, so the index sees constants nothing had
    # touched yet. The Store models bind to an in-memory SQLite database
    # migrated with the wallet's schema, so their column accessors exist;
    # no configured database is read.
    #
    # Rebinds every Store model process-wide, so it belongs in the rake
    # task, never in the unit suite.
    #
    # @return [Array<String>] constants that failed to load (an optional
    #   gem's, say), for the caller to report
    def self.load_all!(lib_dir, namespaces:)
      require 'sequel'
      require File.join(lib_dir, 'bsv-wallet')
      BSV::Wallet::Store.connect('sqlite:/', identity_pubkey_hash: PLACEHOLDER_IDENTITY_HASH).migrate!
      Dir.glob(File.join(lib_dir, '**/*.rb')).each { |path| require path }
      namespaces.each_with_object([]) { |name, failures| force_autoloads(Object.const_get(name), failures) }
    end

    def self.force_autoloads(mod, failures, seen = Set.new)
      return if seen.include?(mod)

      seen << mod
      mod.constants(false).each do |name|
        value = mod.const_get(name, false)
        force_autoloads(value, failures, seen) if value.is_a?(Module) && value.name&.start_with?("#{mod.name}::")
      rescue LoadError, NameError => e
        failures << "#{mod.name}::#{name} (#{e.class})"
      end
      failures
    end

    # @param modules [Array<Module>]
    # @param local_root [String, nil] where the wallet's own code lives.
    #   When a short name matches both a wallet class and an SDK class
    #   (+KeyDeriver+), the wallet's wins: a method only the SDK's has
    #   doesn't make the wallet's reference valid.
    def initialize(modules = ObjectSpace.each_object(Module).to_a, local_root: nil)
      @modules = modules.select { |m| m.name && !m.singleton_class? }
      @local_root = local_root && File.expand_path(local_root)
      # Owners of the methods every object or every class has: without
      # them +Hydrator#select+ would resolve to Kernel's private +select+
      # long after the real one was deleted. Read here, not when this file
      # loads, because the wallet's gems mix more into Object as they load
      # (JSON's +to_json+).
      @universal_owners = (Object.ancestors + Class.ancestors).uniq
    end

    # @param const [String] +A::B+, with or without its leading namespaces
    # @param separator [String, nil] +'#'+ (instance method), +'.'+ (class or module method) or nil
    # @param method_name [String, nil]
    def resolves?(const, separator = nil, method_name = nil)
      return constant?(const) unless separator

      candidates(const).any? { |mod| defines?(mod, separator, method_name.to_sym) }
    end

    # @return [Array<String>] full names of the modules +const+ could mean
    def candidates_for(const)
      candidates(const).map(&:name).sort
    end

    private

    def candidates(const)
      name = const.delete_prefix('::')
      matches = @modules.select { |m| m.name == name || m.name.end_with?("::#{name}") }
      local = matches.select { |m| local?(m) }
      local.empty? ? matches : local
    end

    def local?(mod)
      return false unless @local_root

      file, = Object.const_source_location(mod.name)
      file&.start_with?("#{@local_root}/")
    rescue NameError
      false
    end

    # A module, or a value constant such as +Broadcast::TERMINAL_STATUSES+.
    def constant?(const)
      return true if candidates(const).any?

      parent, _, last = const.rpartition('::')
      !parent.empty? && candidates(parent).any? { |mod| mod.const_defined?(last, false) }
    end

    def defines?(mod, separator, name)
      owner = separator == '#' ? method_owner(mod, name) : method_owner(mod.singleton_class, name)
      return refined?(mod, name) if owner.nil? && separator == '#'
      return false if owner.nil?

      # Object#send is a fair reference; Hydrator#send is not.
      @universal_owners.include?(mod) || (separator == '.' && name == :new) || !@universal_owners.include?(owner)
    end

    def method_owner(mod, name)
      return unless mod.method_defined?(name) || mod.private_method_defined?(name)

      mod.instance_method(name).owner
    end

    # +String#to_dtxid+ exists only inside +using BSV::Wallet::Txid+.
    def refined?(mod, name)
      refinements.any? { |r| r.target == mod && r.method_defined?(name, false) }
    end

    def refinements
      @refinements ||= @modules.grep_v(Refinement).flat_map(&:refinements)
    end
  end
end
