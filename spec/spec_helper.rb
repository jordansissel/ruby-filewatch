require "rspec_sequencing"

def formatted_puts(text)
  txt = RSpec.configuration.format_docstrings_block.call(text)
  RSpec.configuration.output_stream.puts "    #{txt}"
end
