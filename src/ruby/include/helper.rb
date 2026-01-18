require "neo4j_bolt"
require "sinatra/base"

class Main < Sinatra::Base
    include Neo4jBolt

    def assert(condition, message = "assertion failed", suppress_backtrace = false, delay = nil)
        unless condition
            debug_error message
            e = StandardError.new(message)
            e.set_backtrace([]) if suppress_backtrace
            sleep delay unless delay.nil?
            raise e
        end
    end

    def assert_with_delay(condition, message = "assertion failed", suppress_backtrace = false)
        assert(condition, message, suppress_backtrace, 3.0)
    end

    def test_request_parameter(data, key, options)
        type = ((options[:types] || {})[key]) || String
        assert(data[key.to_s].is_a?(type), "#{key.to_s} is a #{type} (it's a #{data[key.to_s].class})")
        if type == String
            assert(data[key.to_s].size <= (options[:max_value_lengths][key] || options[:max_string_length]), "too_much_data")
        end
    end

    def parse_request_data(options = {})
        options[:max_body_length] ||= 512
        options[:max_string_length] ||= 512
        options[:required_keys] ||= []
        options[:optional_keys] ||= []
        options[:max_value_lengths] ||= {}
        data_str = request.body.read(options[:max_body_length]).to_s
        @latest_request_body = data_str.dup
        begin
            assert(data_str.is_a? String)
            assert(data_str.size < options[:max_body_length], "too_much_data")
            data = JSON::parse(data_str)
            @latest_request_body_parsed = data.dup
            result = {}
            options[:required_keys].each do |key|
                assert(data.include?(key.to_s), "missing key: #{key}")
                # test_request_parameter(data, key, options)
                result[key.to_sym] = data[key.to_s]
            end
            options[:optional_keys].each do |key|
                if data.include?(key.to_s)
                    # test_request_parameter(data, key, options)
                    result[key.to_sym] = data[key.to_s]
                end
            end
            result
        rescue
            debug "Request was:"
            debug data_str
            raise
        end
    end

    before "*" do
        @latest_request_body = nil
        @latest_request_body_parsed = nil
    end

    after "*" do
        if response.status.to_i == 200
            if @respond_content
                response.body = @respond_content
                response.headers["Content-Type"] = @respond_mimetype
                if @respond_filename
                    response.headers["Content-Disposition"] = "attachment; filename=\"#{@respond_filename}\""
                end
            else
                @respond_hash ||= {}
                response.body = @respond_hash.to_json
            end
        end
    end

    after '*' do
        cleanup_neo4j()
    end

    def respond(hash = {})
        @respond_hash = hash
    end

    def respond_raw_with_mimetype(content, mimetype)
        @respond_content = content
        @respond_mimetype = mimetype
    end

    def respond_raw_with_mimetype_and_filename(content, mimetype, filename)
        @respond_content = content
        @respond_mimetype = mimetype
        @respond_filename = filename
    end

    def respond_with_file(path, &block)
        unless File.exist?(path)
            status 404
            return
        end
        mime_type = 'text/plain'
        mime_type = 'text/html' if path =~ /\.html$/
        mime_type = 'image/jpeg' if path =~ /\.jpe?g$/
        mime_type = 'image/png' if path =~ /\.png$/
        mime_type = 'image/gif' if path =~ /\.gif$/
        mime_type = 'image/svg' if path =~ /\.svg$/
        mime_type = 'application/pdf' if path =~ /\.pdf$/
        mime_type = 'text/css' if path =~ /\.css$/
        mime_type = 'text/javascript' if path =~ /\.js$/
        mime_type = 'text/json' if path =~ /\.json$/
        mime_type = 'application/manifest+json' if path =~ /\.webmanifest$/
        content = File.read(path)
        if block_given?
            content = yield(content, mime_type)
        end
        respond_raw_with_mimetype(content, mime_type)
    end

    def deliver_mail(plain_text = nil, &block)
        mail = Mail.new do
            charset = 'UTF-8'
            message = self.instance_eval(&block)
            if plain_text.nil?
                html_part do
                    content_type 'text/html; charset=UTF-8'
                    body message
                end

                text_part do
                    content_type 'text/plain; charset=UTF-8'
                    body mail_html_to_plain_text(message)
                end
            else
                text_part do
                    content_type 'text/plain; charset=UTF-8'
                    body plain_text
                end
            end
        end
        if DEVELOPMENT && !SEND_MAILS_IN_DEVELOPMENT
            STDERR.puts "Not sending mail in development mode!"
            STDERR.puts '-' * 40
            STDERR.puts "From:    #{mail.from.join('; ')}"
            STDERR.puts "To:      #{mail.to.join('; ')}"
            STDERR.puts "Subject: #{mail.subject}"
            STDERR.puts mail.text_part
            STDERR.puts '-' * 40
        else
            mail.deliver!
        end
    end

    def mail_html_to_plain_text(s)
        s.gsub('<p>', "\n\n").gsub(/<br\s*\/?>/, "\n").gsub(/<\/?[^>]*>/, '').strip
    end

    # Validate username to ensure it only contains URL-safe characters
    # Allows: lowercase letters, numbers, hyphens, underscores
    # Disallows: spaces, special characters, uppercase (converted to lowercase)
    def validate_username(username)
        return nil if username.nil? || username.strip.empty?
        
        # Convert to lowercase and strip whitespace
        clean_username = username.strip.downcase
        
        # Check if username contains only allowed characters (alphanumeric, hyphen, underscore)
        # This ensures it's URL-safe
        unless clean_username =~ /^[a-z0-9_-]+$/
            return nil
        end
        
        clean_username
    end

    # Sanitize a string to create a valid username
    # Converts email addresses and other strings to URL-safe usernames
    def sanitize_to_username(input)
        return nil if input.nil? || input.strip.empty?
        
        # Convert to lowercase and strip whitespace
        clean = input.strip.downcase
        
        # Remove @ and everything after it (for emails)
        clean = clean.split('@').first
        
        # Replace common separators with hyphens
        clean = clean.gsub(/[.\s]+/, '-')
        
        # Remove any characters that aren't alphanumeric, hyphen, or underscore
        clean = clean.gsub(/[^a-z0-9_-]/, '')
        
        # Remove leading/trailing hyphens
        clean = clean.gsub(/^-+|-+$/, '')
        
        # Return nil if the result is empty
        return nil if clean.empty?
        
        clean
    end

    # Age calculation utilities for ticket age verification
    
    # Validate birthdate format and range
    # Returns [valid, error_message]
    def validate_birthdate(birthdate_str, reference_date = nil)
        return [false, "Geburtsdatum ist erforderlich"] if birthdate_str.nil? || birthdate_str.strip.empty?
        
        begin
            birthdate = Date.parse(birthdate_str)
        rescue ArgumentError
            return [false, "Ungültiges Datumsformat"]
        end
        
        # Check minimum date (1900-01-01)
        min_date = Date.new(1900, 1, 1)
        if birthdate < min_date
            return [false, "Geburtsdatum darf nicht vor dem 01.01.1900 liegen"]
        end
        
        # Check maximum date (reference date or today)
        max_date = reference_date ? (reference_date.is_a?(Date) ? reference_date : Date.parse(reference_date.to_s)) : Date.today
        if birthdate > max_date
            return [false, "Geburtsdatum darf nicht in der Zukunft liegen"]
        end
        
        [true, nil]
    end
    
    # Calculate age in full years on a reference date
    # A birthday on the reference date counts as reached
    def calculate_age(birthdate_str, reference_date = nil)
        birthdate = Date.parse(birthdate_str)
        ref_date = reference_date ? (reference_date.is_a?(Date) ? reference_date : Date.parse(reference_date.to_s)) : Date.today
        
        age = ref_date.year - birthdate.year
        # Subtract 1 if birthday hasn't occurred yet this year
        age -= 1 if ref_date.month < birthdate.month || (ref_date.month == birthdate.month && ref_date.day < birthdate.day)
        age
    end
    
    # Get age category for display
    # Returns: "<14", "<16", "<18", or nil for 18+ or if birthdate is missing
    def get_age_category(birthdate_str, reference_date = nil)
        return nil if birthdate_str.nil? || birthdate_str.to_s.strip.empty?
        
        begin
            age = calculate_age(birthdate_str, reference_date)
            
            return "<14" if age < 14
            return "<16" if age < 16
            return "<18" if age < 18
            nil  # 18+
        rescue ArgumentError
            # Invalid date format
            nil
        end
    end
    
    # Get age status for control/scan view
    # Returns: {category: "...", text: "...", color: "..."} or nil if birthdate is missing
    def get_age_status(birthdate_str, reference_date = nil)
        return nil if birthdate_str.nil? || birthdate_str.to_s.strip.empty?
        
        begin
            age = calculate_age(birthdate_str, reference_date)
            
            if age < 14
                { category: "<14", text: "Ticketinhaber ist unter 14", color: "danger" }
            elsif age < 16
                { category: "<16", text: "Ticketinhaber ist unter 16", color: "warning" }
            elsif age < 18
                { category: "<18", text: "Ticketinhaber ist unter 18", color: "info" }
            else
                { category: "18+", text: "Ticketinhaber ist über 18", color: "success" }
            end
        rescue ArgumentError
            # Invalid date format
            nil
        end
    end
end