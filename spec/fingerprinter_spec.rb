require_relative 'helpers/spec_helper'

describe FileWatch::Fingerprinter do
  # expand these tests
  it "takes a fingerprint" do
    path = FileWatch.path_to_fixture("ten_alpha_lines.txt")
    file = FileWatch::FileOpener.open(path)
    result = FileWatch::Fingerprinter.new(path, 0).read_file(file)
    file.close
    expect(result.data).to eq("aaa\nbbb\nccc\nddd\neee\nfff\nggg\nhhh\niii\njjj\n")
    expect(result.to_a).to eq([15539910233256741944, 0, 40])
    expect(result.size).to eq(40)
    expect(result.data_size).to eq(40)
    expect(result.fingerprint).to eq(15539910233256741944)
    result.add_size(20)
    expect(result.to_a).to eq([18188087011190232688, 0, 20])
    result.add_size(60)
    expect(result.to_a).to eq([15539910233256741944, 0, 40])
  end
end
