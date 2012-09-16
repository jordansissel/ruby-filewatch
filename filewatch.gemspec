Gem::Specification.new do |spec|
  files = []
  dirs = %w{lib samples test bin}
  dirs.each do |dir|
    files += Dir["#{dir}/**/*"]
  end

  spec.name = "filewatch"
  spec.version = "0.4.0"
  spec.summary = "filewatch - file watching for ruby"
  spec.description = "Watch files and directories in ruby. Also supports tailing and glob file patterns."
  spec.files = files
  spec.require_paths << "lib"

  spec.bindir = "bin"
  spec.executables << "globtail"

  spec.authors = ["Jordan Sissel", "Pete Fritchman"]
  spec.email = ["jls@semicomplete.com", "petef@databits.net"]
  spec.homepage = "https://github.com/jordansissel/ruby-filewatch"
end

