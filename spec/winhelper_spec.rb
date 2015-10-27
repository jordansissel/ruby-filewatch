require "stud/temporary"
require "fileutils"

if Gem.win_platform?
  require "lib/filewatch/winhelper"

  describe Winhelper do
    let(:path) { Stud::Temporare.file }

    after do
      FileUtils.rm_rf(path)
    end

    it "return a unique file identifier" do
      volume_serial, file_index_low, file_index_high = Winhelper.GetWindowsUniqueFileIdentifier(path).split("").map(&:to_i)

      expect(volume_serial).not_to eq(0)
      expect(file_index_low).not_to eq(0)
      expect(file_index_high).not_to eq(0)
    end
  end
end
