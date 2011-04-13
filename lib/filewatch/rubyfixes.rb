
# Ruby <= 1.8.6 doesn't have String#bytesize
# FFI 1.0.7 wants it. Monkeypatch time.
if !String.instance_methods.include?("bytesize")
  class String
    alias :bytesize :size
  end
end
