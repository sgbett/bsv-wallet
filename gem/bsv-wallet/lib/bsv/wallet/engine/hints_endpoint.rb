# frozen_string_literal: true

module BSV
  module Wallet
    class Engine
      # The hints socket's trust boundary, decided in #269 and enforced
      # here (#556). The socket is unauthenticated, so who can connect to
      # it is who can feed +walletd+'s cache: it must be reachable by the
      # wallet's own user alone. That rules out every transport but an
      # +ipc://+ filesystem path (and +inproc://+, which never leaves the
      # process): +tcp://+ reaches other hosts, and a Linux abstract socket
      # (+ipc://@name+) has no file permissions, so any local user can
      # connect.
      module HintsEndpoint
        IPC = 'ipc://'
        INPROC = 'inproc://'
        # A Unix socket file is created 0777 less the umask, so 0600.
        OWNER_ONLY_UMASK = 0o177
        GROUP_OR_WORLD_WRITABLE = 0o022

        module_function

        # @param endpoint [String] an OMQ endpoint
        # @return [String] +endpoint+, when the hints socket may use it
        # @raise [ConfigurationError] for anything but an +ipc://+
        #   filesystem path or an +inproc://+ endpoint
        def validate!(endpoint)
          return endpoint if endpoint.start_with?(INPROC)

          unless endpoint.start_with?(IPC)
            raise ConfigurationError,
                  "hints socket #{endpoint} refused: it must be an ipc:// filesystem path, " \
                  'which only the wallet\'s user can reach'
          end

          path = endpoint.delete_prefix(IPC)
          raise ConfigurationError, "hints socket #{endpoint} has no path" if path.empty?
          if path.start_with?('@')
            raise ConfigurationError,
                  "hints socket #{endpoint} refused: an abstract socket has no file permissions, " \
                  'so any local user could connect'
          end

          endpoint
        end

        # Bind +socket+ to +endpoint+ once the endpoint passes {.validate!}.
        # For an +ipc://+ path, the socket's directory must belong to the
        # wallet's user and be writable by nobody else, so no one else can
        # replace the socket; the path must be free or hold a stale socket
        # of the user's own; and the socket file is created owner-only.
        #
        # @param socket [OMQ::Socket] an unbound socket
        # @param endpoint [String]
        # @raise [ConfigurationError] when the endpoint, its directory or
        #   whatever already sits at its path is refused
        def bind(socket, endpoint)
          validate!(endpoint)
          return socket.bind(endpoint) if endpoint.start_with?(INPROC)

          # Neither +~+ nor a relative path is expanded: the bind resolves
          # the path as given, so the checks must see the same directory.
          path = endpoint.delete_prefix(IPC)
          check_directory!(File.dirname(path))
          check_path_free!(path)
          bind_owner_only(socket, endpoint)
        end

        def check_directory!(dir)
          stat = File.stat(dir)
          raise ConfigurationError, "hints socket directory #{dir} is not a directory" unless stat.directory?
          raise ConfigurationError, "hints socket directory #{dir} is owned by another user" unless stat.owned?
          return unless stat.mode.anybits?(GROUP_OR_WORLD_WRITABLE)

          raise ConfigurationError,
                "hints socket directory #{dir} is group- or world-writable; " \
                'use a directory only the wallet\'s user can write to'
        rescue Errno::ENOENT, Errno::ENOTDIR
          raise ConfigurationError, "hints socket directory #{dir} does not exist"
        end

        # OMQ deletes whatever is at the path before it binds, so a
        # mistyped path must not reach it.
        def check_path_free!(path)
          return unless File.exist?(path) || File.symlink?(path)

          stat = File.lstat(path)
          return if stat.socket? && stat.owned?

          raise ConfigurationError,
                "hints socket path #{path} already exists and is not this user's socket; binding would delete it"
        end

        # Warning: the umask is process-wide, so a file another thread
        # creates during the bind is also created owner-only: more
        # private, never less. Setting the mode after the bind instead
        # would leave a window in which another user could connect.
        def bind_owner_only(socket, endpoint)
          saved = File.umask(OWNER_ONLY_UMASK)
          socket.bind(endpoint)
        ensure
          File.umask(saved) if saved
        end

        private_class_method :check_directory!, :check_path_free!, :bind_owner_only
      end
    end
  end
end
