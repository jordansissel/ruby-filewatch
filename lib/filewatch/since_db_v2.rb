module FileWatch
  class SinceDbV2 < SinceDb

    def version_match?(line)
      split_line(line.size).first.include?("|")
    end

    private

    def storage_key(wf)
      wf.sdb_key_v2
    end
  end
end
