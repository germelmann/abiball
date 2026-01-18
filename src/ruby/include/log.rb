class Main < Sinatra::Base
    def print_logs()
        require_user_with_permission!("view_logs")
        StringIO.open do |s|
            lines = []
            File.open('/gen/log/log.txt', 'r:ISO-8859-1') do |f|
            f.each_line do |line|
                lines << "#{line.chomp}"
            end
            end
            lines.reverse.each do |line|
            s.puts line
            end
            s.rewind
            s.string
        end
    end

    def log(message)
        entry = "#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}, #{@session_user ? @session_user[:name] : 'Unknown'}: #{message}"
        FileUtils::mkpath('/gen/log')
        File.open('/gen/log/log.txt', 'a:ISO-8859-1') do |f|
            f.puts entry.encode("ISO-8859-1", invalid: :replace, undef: :replace, replace: "")
        end
    end
end
