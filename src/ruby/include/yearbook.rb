require 'csv'

class Main < Sinatra::Base

    MAX_YEARBOOK_FIELD_LENGTH = 2000

    def yearbook_timestamp
        DateTime.now.to_s
    end

    # Check if yearbook is currently accessible based on credentials configuration
    def yearbook_accessible?
        return false unless defined?(YEARBOOK_ENABLED) && YEARBOOK_ENABLED

        now = DateTime.now
        if defined?(YEARBOOK_START_AT) && YEARBOOK_START_AT
            return false if now < DateTime.parse(YEARBOOK_START_AT.to_s)
        end
        if defined?(YEARBOOK_END_AT) && YEARBOOK_END_AT
            return false if now > DateTime.parse(YEARBOOK_END_AT.to_s)
        end

        true
    end

    def require_yearbook_accessible!
        assert(yearbook_accessible?, "Jahrbuch ist derzeit nicht verfügbar")
    end

    def yearbook_questions
        return [] unless defined?(YEARBOOK_QUESTIONS)
        YEARBOOK_QUESTIONS
    end

    def yearbook_profile_fields
        return [] unless defined?(YEARBOOK_PROFILE_FIELDS)
        YEARBOOK_PROFILE_FIELDS
    end

    # Helper: build profile RETURN clause with individual properties (avoids datetime parsing issues)
    def yearbook_profile_return_fields
        yearbook_profile_fields.map { |f|
            assert(f[:id] =~ /\A[a-zA-Z_][a-zA-Z0-9_]*\z/, "Ungültige Feld-ID")
            "yp.#{f[:id]} AS yp_#{f[:id]}"
        }.join(', ')
    end

    # Helper: extract profile data from a query result row
    def extract_profile_from_row(row)
        profile_data = {}
        yearbook_profile_fields.each do |field|
            profile_data[field[:id]] = row["yp_#{field[:id]}"] || ''
        end
        profile_data
    end

    # Helper: build and execute yearbook profile save query
    def save_yearbook_profile(username, fields)
        valid_fields = yearbook_profile_fields.map { |f| f[:id] }
        set_parts = []
        params = { username: username, profile_id: "yp_#{username}", now: yearbook_timestamp }

        valid_fields.each do |field_id|
            assert(field_id =~ /\A[a-zA-Z_][a-zA-Z0-9_]*\z/, "Ungültige Feld-ID")
            value = (fields[field_id] || '').to_s[0, MAX_YEARBOOK_FIELD_LENGTH]
            param_key = "field_#{field_id}".to_sym
            params[param_key] = value
            set_parts << "yp.#{field_id} = $#{param_key}"
        end

        set_clause = set_parts.join(", ")

        neo4j_query(<<~END_OF_QUERY, params)
            MATCH (u:User {username: $username})
            MERGE (u)-[:HAS_YEARBOOK_PROFILE]->(yp:YearbookProfile {id: $profile_id})
            SET #{set_clause}, yp.updated_at = $now
        END_OF_QUERY
    end

    # Helper: save a yearbook answer for a user
    def save_yearbook_answer(username, question_id, answer)
        question = yearbook_questions.find { |q| q[:id] == question_id }
        assert(question, "Ungültige Frage")

        case question[:type]
        when 'single_choice'
            assert(answer.is_a?(String), "Ungültige Antwort")
            assert(question[:options].include?(answer), "Ungültige Auswahloption") unless answer.empty?
        when 'multiple_choice'
            assert(answer.is_a?(Array), "Ungültige Antwort")
            answer.each do |a|
                assert(question[:options].include?(a), "Ungültige Auswahloption: #{a}")
            end
        when 'text'
            assert(answer.is_a?(String), "Ungültige Antwort")
        else
            assert(false, "Unbekannter Fragetyp")
        end

        answer_str = answer.is_a?(Array) ? answer.to_json : answer.to_s
        entry_id = "#{username}_#{question_id}"

        neo4j_query(<<~END_OF_QUERY, {username: username, question_id: question_id, answer: answer_str, entry_id: entry_id, now: yearbook_timestamp})
            MATCH (u:User {username: $username})
            MERGE (u)-[:HAS_YEARBOOK_ENTRY]->(y:YearbookEntry {id: $entry_id})
            SET y.question_id = $question_id,
                y.answer = $answer,
                y.updated_at = $now
        END_OF_QUERY
    end

    # Helper: get yearbook profile data for a user
    def get_yearbook_profile_data(username)
        return_fields = yearbook_profile_return_fields
        return {} if return_fields.empty?

        result = neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})-[:HAS_YEARBOOK_PROFILE]->(yp:YearbookProfile)
            RETURN #{return_fields}
        END_OF_QUERY

        return {} if result.empty?
        extract_profile_from_row(result.first)
    end

    # Helper: collect all yearbook data for export/management
    def collect_all_yearbook_data
        entries = neo4j_query(<<~END_OF_QUERY)
            MATCH (u:User)-[:HAS_YEARBOOK_ENTRY]->(y:YearbookEntry)
            RETURN u.username AS username, u.name AS name,
                   y.question_id AS question_id, y.answer AS answer
        END_OF_QUERY

        return_fields = yearbook_profile_return_fields
        profiles = if return_fields.empty?
            []
        else
            neo4j_query(<<~END_OF_QUERY)
                MATCH (u:User)-[:HAS_YEARBOOK_PROFILE]->(yp:YearbookProfile)
                RETURN u.username AS username, u.name AS name, #{return_fields}
            END_OF_QUERY
        end

        questions = yearbook_questions

        user_answers = {}
        entries.each do |entry|
            q = questions.find { |qq| qq[:id] == entry['question_id'] }
            next unless q

            if q[:anonymous]
                user_answers['__anonymous'] ||= {}
                user_answers['__anonymous'][entry['question_id']] ||= []
                user_answers['__anonymous'][entry['question_id']] << entry['answer']
            else
                uname = entry['username']
                user_answers[uname] ||= { name: entry['name'], answers: {} }
                user_answers[uname][:answers][entry['question_id']] = entry['answer']
            end
        end

        profile_list = profiles.map do |p|
            {
                username: p['username'],
                name: p['name'],
                profile: extract_profile_from_row(p)
            }
        end

        {
            user_answers: user_answers,
            profiles: profile_list,
            questions: questions
        }
    end

    # Get yearbook configuration (questions + profile fields)
    post '/api/yearbook/config' do
        require_user!
        require_yearbook_accessible!

        questions_config = yearbook_questions.map do |q|
            {
                id: q[:id],
                type: q[:type],
                question: q[:question],
                options: q[:options] || [],
                anonymous: q[:anonymous] || false
            }
        end

        respond(
            success: true,
            questions: questions_config,
            profile_fields: yearbook_profile_fields
        )
    end

    # Get current user's yearbook answers
    post '/api/yearbook/get_my_answers' do
        require_user!
        require_yearbook_accessible!
        require_user_with_permission!("yearbook_create")

        username = @session_user[:username]

        entries = neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})-[:HAS_YEARBOOK_ENTRY]->(y:YearbookEntry)
            RETURN y.id AS id, y.question_id AS question_id, y.answer AS answer
        END_OF_QUERY

        answers = {}
        entries.each do |entry|
            answers[entry['question_id']] = entry['answer']
        end

        respond(success: true, answers: answers)
    end

    # Save current user's yearbook answer for a specific question
    post '/api/yearbook/save_answer' do
        require_user!
        require_yearbook_accessible!
        require_user_with_permission!("yearbook_create")

        data = parse_request_data(
            required_keys: [:question_id, :answer],
            max_body_length: 8192,
            max_string_length: 4096
        )

        question_id = data[:question_id].to_s.strip
        answer = data[:answer]
        username = @session_user[:username]

        save_yearbook_answer(username, question_id, answer)

        respond(success: true, message: "Antwort gespeichert")
    end

    # Get current user's yearbook profile (Steckbrief)
    post '/api/yearbook/get_my_profile' do
        require_user!
        require_yearbook_accessible!
        require_user_with_permission!("yearbook_create")

        username = @session_user[:username]
        profile_data = get_yearbook_profile_data(username)

        respond(success: true, profile: profile_data)
    end

    # Save current user's yearbook profile (Steckbrief)
    post '/api/yearbook/save_profile' do
        require_user!
        require_yearbook_accessible!
        require_user_with_permission!("yearbook_create")

        data = parse_request_data(
            required_keys: [:fields],
            max_body_length: 16384,
            max_string_length: 8192
        )

        fields = data[:fields]
        assert(fields.is_a?(Hash), "Ungültige Felder")
        username = @session_user[:username]

        save_yearbook_profile(username, fields)

        respond(success: true, message: "Steckbrief gespeichert")
    end

    # Get all yearbook entries (for yearbook_view or yearbook_manage roles)
    post '/api/yearbook/get_all_entries' do
        require_user!
        require_yearbook_accessible!

        has_view = user_has_permission?("yearbook_view")
        has_manage = user_has_permission?("yearbook_manage")
        assert(has_view || has_manage, "Keine Berechtigung")

        data = collect_all_yearbook_data

        respond(
            success: true,
            user_answers: data[:user_answers],
            profiles: data[:profiles],
            questions: data[:questions].map { |q| { id: q[:id], question: q[:question], type: q[:type], anonymous: q[:anonymous], options: q[:options] || [] } }
        )
    end

    # Get a specific user's yearbook entry (for yearbook_view or yearbook_manage)
    post '/api/yearbook/get_user_entry' do
        require_user!
        require_yearbook_accessible!

        has_view = user_has_permission?("yearbook_view")
        has_manage = user_has_permission?("yearbook_manage")
        assert(has_view || has_manage, "Keine Berechtigung")

        data = parse_request_data(required_keys: [:target_username])
        target_username = data[:target_username].to_s.strip

        user_info = neo4j_query(<<~END_OF_QUERY, {username: target_username})
            MATCH (u:User {username: $username})
            RETURN u.username AS username, u.name AS name
        END_OF_QUERY
        assert(!user_info.empty?, "Benutzer nicht gefunden")

        entries = neo4j_query(<<~END_OF_QUERY, {username: target_username})
            MATCH (u:User {username: $username})-[:HAS_YEARBOOK_ENTRY]->(y:YearbookEntry)
            RETURN y.question_id AS question_id, y.answer AS answer
        END_OF_QUERY

        answers = {}
        entries.each do |entry|
            answers[entry['question_id']] = entry['answer']
        end

        profile_data = get_yearbook_profile_data(target_username)

        questions = yearbook_questions.map { |q| { id: q[:id], question: q[:question], type: q[:type], anonymous: q[:anonymous], options: q[:options] || [] } }

        respond(
            success: true,
            username: user_info.first['username'],
            name: user_info.first['name'],
            answers: answers,
            profile: profile_data,
            questions: questions,
            profile_fields: yearbook_profile_fields,
            can_manage: has_manage
        )
    end

    # Admin: save answer for another user (yearbook_manage only)
    post '/api/yearbook/admin_save_answer' do
        require_user!
        require_yearbook_accessible!
        require_user_with_permission!("yearbook_manage")

        data = parse_request_data(
            required_keys: [:target_username, :question_id, :answer],
            max_body_length: 8192,
            max_string_length: 4096
        )

        target_username = data[:target_username].to_s.strip
        question_id = data[:question_id].to_s.strip
        answer = data[:answer]

        user_exists = neo4j_query(<<~END_OF_QUERY, {username: target_username})
            MATCH (u:User {username: $username})
            RETURN u.username AS username
        END_OF_QUERY
        assert(!user_exists.empty?, "Benutzer nicht gefunden")

        save_yearbook_answer(target_username, question_id, answer)

        log("Jahrbuch-Antwort für #{target_username} (Frage: #{question_id}) geändert")
        respond(success: true, message: "Antwort gespeichert")
    end

    # Admin: save profile for another user (yearbook_manage only)
    post '/api/yearbook/admin_save_profile' do
        require_user!
        require_yearbook_accessible!
        require_user_with_permission!("yearbook_manage")

        data = parse_request_data(
            required_keys: [:target_username, :fields],
            max_body_length: 16384,
            max_string_length: 8192
        )

        target_username = data[:target_username].to_s.strip
        fields = data[:fields]
        assert(fields.is_a?(Hash), "Ungültige Felder")

        user_exists = neo4j_query(<<~END_OF_QUERY, {username: target_username})
            MATCH (u:User {username: $username})
            RETURN u.username AS username
        END_OF_QUERY
        assert(!user_exists.empty?, "Benutzer nicht gefunden")

        save_yearbook_profile(target_username, fields)

        log("Jahrbuch-Steckbrief für #{target_username} geändert")
        respond(success: true, message: "Steckbrief gespeichert")
    end

    # Get list of all users for selection dropdowns in yearbook questions
    post '/api/yearbook/get_users_list' do
        require_user!
        require_yearbook_accessible!

        users = neo4j_query(<<~END_OF_QUERY)
            MATCH (u:User)
            WHERE COALESCE(u.scanner_only, false) = false
            RETURN u.username AS username, u.name AS name
            ORDER BY u.name
        END_OF_QUERY

        respond(success: true, users: users)
    end

    # Export yearbook data as JSON
    get '/api/yearbook/export_json' do
        require_user!
        require_yearbook_accessible!
        require_user_with_permission!("yearbook_view")

        data = collect_all_yearbook_data
        questions = data[:questions]

        export = {
            exported_at: yearbook_timestamp,
            profiles: data[:profiles],
            questions: questions.map { |q| { id: q[:id], question: q[:question], type: q[:type], anonymous: q[:anonymous] } },
            answers: data[:user_answers],
            profile_fields: yearbook_profile_fields
        }

        respond_raw_with_mimetype_and_filename(
            JSON.pretty_generate(export),
            'application/json',
            "jahrbuch_export_#{Date.today}.json"
        )
    end

    # Export yearbook data as CSV
    get '/api/yearbook/export_csv' do
        require_user!
        require_yearbook_accessible!
        require_user_with_permission!("yearbook_view")

        data = collect_all_yearbook_data
        questions = data[:questions]
        non_anon_questions = questions.select { |q| !q[:anonymous] }
        profile_fields = yearbook_profile_fields

        # Collect all usernames from answers and profiles
        all_usernames = Set.new
        data[:user_answers].each_key { |k| all_usernames << k unless k == '__anonymous' }
        data[:profiles].each { |p| all_usernames << p[:username] }

        csv_string = CSV.generate(col_sep: ';', encoding: 'UTF-8') do |csv|
            # Header row
            header = ['Benutzername', 'Name']
            profile_fields.each { |f| header << f[:label] }
            non_anon_questions.each { |q| header << q[:question] }
            csv << header

            # Data rows
            all_usernames.sort.each do |username|
                row = [username]

                user_data = data[:user_answers][username]
                profile = data[:profiles].find { |p| p[:username] == username }

                row << (user_data ? user_data[:name] : (profile ? profile[:name] : ''))

                profile_fields.each do |f|
                    row << (profile ? (profile[:profile][f[:id]] || '') : '')
                end

                non_anon_questions.each do |q|
                    answer = user_data && user_data[:answers] ? (user_data[:answers][q[:id]] || '') : ''
                    begin
                        parsed = JSON.parse(answer)
                        answer = parsed.join(', ') if parsed.is_a?(Array)
                    rescue
                    end
                    row << answer
                end

                csv << row
            end
        end

        respond_raw_with_mimetype_and_filename(
            "\xEF\xBB\xBF" + csv_string,
            'text/csv; charset=utf-8',
            "jahrbuch_export_#{Date.today}.csv"
        )
    end
end
