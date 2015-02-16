require 'filewatch/buftok'

describe FileWatch::BufferedTokenizer do

  context "when using the default delimiter" do
    subject { FileWatch::BufferedTokenizer.new }

    it "splits the lines correctly" do
      message = "hello\nworld\n"
      expect(subject.extract(message)).to eq ["hello", "world"]
    end
  end

  context "when passing a custom delimiter" do
    subject { FileWatch::BufferedTokenizer.new("\r\n") }

    it "splits the lines correctly" do
      message = "hello\r\nworld\r\n"
      expect(subject.extract(message)).to eq ["hello", "world"]
    end
  end
end
