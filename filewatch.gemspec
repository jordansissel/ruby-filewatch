Gem::Specification.new do |spec|
  files = []
  dirs = %w{lib samples test bin}
  dirs.each do |dir|
    files += Dir["#{dir}/**/*"]
  end

  spec.name = "filewatch"
  spec.version = "0.0.3"
  spec.summary = "filewatch - file watching for ruby"
  spec.description = "Watch files and directories in ruby"
  spec.files = files
  spec.require_paths << "lib"

  spec.author = "Jordan Sissel"
  spec.email = "jls@semicomplete.com"
  spec.homepage = "https://github.com/jordansissel/ruby-inotify-ffi"
end

