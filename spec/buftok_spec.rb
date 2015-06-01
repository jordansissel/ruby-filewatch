require 'filewatch/buftok'

describe FileWatch::BufferedTokenizer do

  context "when using the default delimiter" do
    it "splits the lines correctly" do
      expect(subject.extract("hello\nworld\n")).to eq ["hello", "world"]
    end
  end

  context "when passing a custom delimiter" do
    subject { FileWatch::BufferedTokenizer.new("\r\n") }

    it "splits the lines correctly" do
      expect(subject.extract("hello\r\nworld\r\n")).to eq ["hello", "world"]
    end
  end
end
