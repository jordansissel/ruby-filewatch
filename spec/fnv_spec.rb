require_relative 'helpers/spec_helper'

describe "FNV based fingerprints of files" do
  let(:data) do
    File.open(FileWatch.path_to_fixture("twenty_six_lines.txt"), "rb") do |f|
      f.read(255)
    end
  end

  subject { FileWatch::Fnv.new(data) }

  describe "public API" do
    it("#close"){ expect(subject).to respond_to(:close)}
    it("#closed?"){ expect(subject).to respond_to(:closed?)}
    it("#open?"){ expect(subject).to respond_to(:open?)}
    it("#fnv1a32"){ expect(subject).to respond_to(:fnv1a32)}
    it("#fnv1a64"){ expect(subject).to respond_to(:fnv1a64)}
  end

  context "when the length wanted is 255 - the same as the data.bytesize" do
    let(:how_much) { 255 }

    it "returns the 32 bit fingerprint of the data" do
      expect(subject.fnv1a32).to eq(2693357799)
    end

    it "returns the 64 bit fingerprint of the data" do
      expect(subject.fnv1a64).to eq(1180824822273425351)
    end
  end

  context "when the length wanted is 125 - less than data.bytesize" do
    let(:how_much) { 125 }

    it "returns the 32 bit fingerprint of the data" do
      expect(subject.fnv1a32(how_much.to_i)).to eq(4052088230)
    end

    it "returns the 64 bit fingerprint of the data" do
      expect(subject.fnv1a64(how_much.to_i)).to eq(4547258229909503046)
    end
  end

  context "when given a known string" do
    let(:data) { "line 1\nline 2\nline 3" }
    it "returns a known fingeprint" do
      expect(subject.fnv1a64).to eq(8658598129674203459)
    end
  end

  context("when closed") do
    it "raises an exception" do
      subject.close
      expect{subject.fnv1a64}.to raise_exception("Fnv instance is closed!")
    end
  end
end
