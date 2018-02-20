if defined?(JRUBY_VERSION)
  require_relative 'helpers/spec_helper'

  describe FileWatch::FileExt do
    it "opens files" do
      file = FileWatch::FileExt.open(FileWatch.path_to_fixture("ten_alpha_lines.txt"))
      result = file.read(3)
      file.close
      expect(result).to eq("aaa")
    end
  end
end
