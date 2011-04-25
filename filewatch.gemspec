Gem::Specification.new do |spec|
  files = []
  dirs = %w{lib samples test bin}
  dirs.each do |dir|
    files += Dir["#{dir}/**/*"]
  end

  spec.name = "filewatch"
  spec.version = "0.2.5"
  spec.summary = "filewatch - file watching for ruby"
  spec.description = "Watch files and directories in ruby. Also supports tailing and glob file patterns. Works with plain ruby, EventMachine, and JRuby"
  spec.files = files
  spec.require_paths << "lib"

  # We use FFI to talk to inotify, etc.
  spec.add_dependency("ffi")

  spec.bindir = "bin"
  spec.executables << "gtail"

  spec.author = "Jordan Sissel"
  spec.email = "jls@semicomplete.com"
  spec.homepage = "https://github.com/jordansissel/ruby-filewatch"
end

