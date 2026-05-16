require 'csv'
require 'fileutils'

class Main < Sinatra::Base

    MAX_YEARBOOK_FIELD_LENGTH = 2000
    MAX_YEARBOOK_COMMENT_LENGTH = 1000
    YEARBOOK_UPLOAD_PATH = '/raw/yearbook_uploads'

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

    def yearbook_allow_delete_all?
        defined?(YEARBOOK_ALLOW_DELETE_ALL) && YEARBOOK_ALLOW_DELETE_ALL
    end

    def yearbook_schueler
        return [] unless defined?(SCHUELER)
        SCHUELER
    end

    # Sync SCHUELER list from credentials into the database (idempotent MERGE).
    def sync_schueler_to_db!
        schueler = yearbook_schueler
        return if schueler.empty?
        schueler.each do |s|
            neo4j_query(<<~END_OF_QUERY, { id: s[:id].to_s, name: s[:name].to_s })
                MERGE (s:Schueler {id: $id})
                SET s.name = $name
            END_OF_QUERY
        end
    end

    @@schueler_sync_mutex = Mutex.new
    # Helper: resolve the effective username for an operation.
    # If target_username is blank/nil, returns the session user's username.
    # If a non-empty target_username is provided, the caller must have yearbook_manage permission.
    def resolve_target_username(target_username)
        t = target_username.to_s.strip
        return @session_user[:username] if t.empty?
        assert(user_has_permission?("yearbook_manage"), "Keine Berechtigung für anderen Benutzer")
        user_exists = neo4j_query(<<~END_OF_QUERY, {username: t})
            MATCH (u:User {username: $username}) RETURN u.username AS username
        END_OF_QUERY
        assert(!user_exists.empty?, "Benutzer nicht gefunden")
        t
    end

    @@schueler_synced = false

    def ensure_schueler_synced!
        return if @@schueler_synced
        @@schueler_sync_mutex.synchronize do
            return if @@schueler_synced
            sync_schueler_to_db!
            @@schueler_synced = true
        end
    end

    # Helper: build profile RETURN clause for non-upload fields
    def yearbook_profile_return_fields
        yearbook_profile_fields.select { |f| f[:type] != 'upload' }.map { |f|
            assert(f[:id] =~ /\A[a-zA-Z_][a-zA-Z0-9_]*\z/, "Ungültige Feld-ID")
            "yp.#{f[:id]} AS yp_#{f[:id]}"
        }.join(', ')
    end

    # Helper: extract profile data from a query result row
    def extract_profile_from_row(row)
        profile_data = {}
        yearbook_profile_fields.each do |field|
            next if field[:type] == 'upload'
            profile_data[field[:id]] = row["yp_#{field[:id]}"] || ''
        end
        profile_data
    end

    # Helper: build and execute yearbook profile save query
    def save_yearbook_profile(username, fields)
        valid_fields = yearbook_profile_fields.select { |f| f[:type] != 'upload' }.map { |f| f[:id] }
        set_parts = []
        params = { username: username, profile_id: "yp_#{username}", now: yearbook_timestamp }

        valid_fields.each do |field_id|
            assert(field_id =~ /\A[a-zA-Z_][a-zA-Z0-9_]*\z/, "Ungültige Feld-ID")
            value = (fields[field_id] || '').to_s[0, MAX_YEARBOOK_FIELD_LENGTH]
            param_key = "field_#{field_id}".to_sym
            params[param_key] = value
            set_parts << "yp.#{field_id} = $#{param_key}"
        end

        if set_parts.empty?
            # Edge case: all profile fields are upload type (no text/textarea fields).
            # Still ensure the profile node exists so uploads can be associated with it
            # and the user appears in the profiles list.
            neo4j_query(<<~END_OF_QUERY, { username: username, profile_id: "yp_#{username}", now: yearbook_timestamp })
                MATCH (u:User {username: $username})
                MERGE (u)-[:HAS_YEARBOOK_PROFILE]->(yp:YearbookProfile {id: $profile_id})
                SET yp.updated_at = $now
            END_OF_QUERY
            return
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
        assert(question[:type] != 'upload', "Upload-Felder werden separat verwaltet")

        case question[:type]
        when 'single_choice'
            assert(answer.is_a?(String), "Ungültige Antwort")
            assert(question[:options].include?(answer), "Ungültige Auswahloption") unless answer.empty?
        when 'multiple_choice'
            assert(answer.is_a?(Array), "Ungültige Antwort")
            answer.each do |a|
                assert(question[:options].include?(a), "Ungültige Auswahloption: #{a}")
            end
        when 'text', 'textarea'
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

        if return_fields.empty?
            result = neo4j_query(<<~END_OF_QUERY, {username: username})
                MATCH (u:User {username: $username})-[:HAS_YEARBOOK_PROFILE]->(yp:YearbookProfile)
                RETURN 1 AS exists
            END_OF_QUERY
            return result.empty? ? nil : {}
        end

        result = neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})-[:HAS_YEARBOOK_PROFILE]->(yp:YearbookProfile)
            RETURN #{return_fields}
        END_OF_QUERY

        return nil if result.empty?
        extract_profile_from_row(result.first)
    end

    # Helper: get uploads for a user filtered by context and optionally field_id
    def get_yearbook_uploads_for_user(username, context, field_id = nil)
        if field_id
            results = neo4j_query(<<~END_OF_QUERY, {username: username, context: context, field_id: field_id})
                MATCH (u:User {username: $username})-[:HAS_YEARBOOK_UPLOAD]->(up:YearbookUpload {context: $context, field_id: $field_id})
                RETURN up.id AS id, up.original_filename AS filename, up.mimetype AS mimetype,
                       up.field_id AS field_id, up.context AS context
                ORDER BY up.created_at
            END_OF_QUERY
        else
            results = neo4j_query(<<~END_OF_QUERY, {username: username, context: context})
                MATCH (u:User {username: $username})-[:HAS_YEARBOOK_UPLOAD]->(up:YearbookUpload {context: $context})
                RETURN up.id AS id, up.original_filename AS filename, up.mimetype AS mimetype,
                       up.field_id AS field_id, up.context AS context
                ORDER BY up.created_at
            END_OF_QUERY
        end
        results.map { |r| { id: r['id'], filename: r['filename'], mimetype: r['mimetype'], field_id: r['field_id'], context: r['context'] } }
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
            neo4j_query(<<~END_OF_QUERY)
                MATCH (u:User)-[:HAS_YEARBOOK_PROFILE]->(yp:YearbookProfile)
                RETURN u.username AS username, u.name AS name
            END_OF_QUERY
        else
            neo4j_query(<<~END_OF_QUERY)
                MATCH (u:User)-[:HAS_YEARBOOK_PROFILE]->(yp:YearbookProfile)
                RETURN u.username AS username, u.name AS name, #{return_fields}
            END_OF_QUERY
        end

        questions = yearbook_questions

        user_answers = {}
        # Attributed anonymous answers: keyed by question_id -> [{username, name, answer}]
        # Only included in the response for yearbook_manage users.
        attributed_anonymous = {}

        entries.each do |entry|
            q = questions.find { |qq| qq[:id] == entry['question_id'] }
            next unless q
            next if q[:type] == 'upload'

            if q[:anonymous]
                user_answers['__anonymous'] ||= {}
                user_answers['__anonymous'][entry['question_id']] ||= []
                user_answers['__anonymous'][entry['question_id']] << entry['answer']

                attributed_anonymous[entry['question_id']] ||= []
                attributed_anonymous[entry['question_id']] << {
                    username: entry['username'],
                    name: entry['name'],
                    answer: entry['answer']
                }
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
                profile: return_fields.empty? ? {} : extract_profile_from_row(p)
            }
        end

        {
            user_answers: user_answers,
            attributed_anonymous: attributed_anonymous,
            profiles: profile_list,
            questions: questions
        }
    end

    # Helper: delete all yearbook data for a user
    def delete_yearbook_entry_for_user(username)
        uploads = neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})-[:HAS_YEARBOOK_UPLOAD]->(up:YearbookUpload)
            RETURN up.id AS id, up.original_filename AS filename
        END_OF_QUERY
        uploads.each do |up|
            file_path = File.join(YEARBOOK_UPLOAD_PATH, "#{up['id']}_#{up['filename']}")
            File.delete(file_path) if File.exist?(file_path)
        end

        neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})-[:HAS_YEARBOOK_UPLOAD]->(up:YearbookUpload)
            DETACH DELETE up
        END_OF_QUERY
        neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})-[:HAS_YEARBOOK_ENTRY]->(y:YearbookEntry)
            DETACH DELETE y
        END_OF_QUERY
        neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})-[:HAS_YEARBOOK_PROFILE]->(yp:YearbookProfile)
            DETACH DELETE yp
        END_OF_QUERY
        # Delete comments written by this user (they are the author)
        neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})-[:WROTE_YEARBOOK_COMMENT]->(c:YearbookComment)
            DETACH DELETE c
        END_OF_QUERY
        # Note: comments received on the user's Schueler node are not deleted here;
        # the IS_SCHUELER assignment remains intact.
    end

    # Get yearbook configuration (questions + profile fields)
    post '/api/yearbook/config' do
        require_user_with_permission!("yearbook_create")
        require_yearbook_accessible!

        questions_config = yearbook_questions.map do |q|
            {
                id: q[:id],
                type: q[:type],
                question: q[:question],
                options: q[:options] || [],
                anonymous: q[:anonymous] || false,
                max_file_size: q[:max_file_size],
                max_uploads: q[:max_uploads]
            }
        end

        profile_fields_config = yearbook_profile_fields.map do |f|
            {
                id: f[:id],
                label: f[:label],
                type: f[:type],
                max_file_size: f[:max_file_size],
                max_uploads: f[:max_uploads]
            }
        end

        respond(
            success: true,
            questions: questions_config,
            profile_fields: profile_fields_config,
            allow_delete_all: yearbook_allow_delete_all?
        )
    end

    # Get current user's yearbook answers (or another user's if yearbook_manage)
    post '/api/yearbook/get_my_answers' do
        require_user_with_permission!("yearbook_create")
        require_yearbook_accessible!

        data = parse_request_data(optional_keys: [:target_username])
        target_username = resolve_target_username(data[:target_username])

        entries = neo4j_query(<<~END_OF_QUERY, {username: target_username})
            MATCH (u:User {username: $username})-[:HAS_YEARBOOK_ENTRY]->(y:YearbookEntry)
            RETURN y.id AS id, y.question_id AS question_id, y.answer AS answer
        END_OF_QUERY

        answers = {}
        entries.each do |entry|
            answers[entry['question_id']] = entry['answer']
        end

        respond(success: true, answers: answers)
    end

    # Save yearbook answer (own or target user's if yearbook_manage)
    post '/api/yearbook/save_answer' do
        require_user_with_permission!("yearbook_create")
        require_yearbook_accessible!

        data = parse_request_data(
            required_keys: [:question_id, :answer],
            optional_keys: [:target_username],
            max_body_length: 8192,
            max_string_length: 4096
        )

        question_id = data[:question_id].to_s.strip
        answer = data[:answer]
        username = resolve_target_username(data[:target_username])

        save_yearbook_answer(username, question_id, answer)

        respond(success: true, message: "Antwort gespeichert")
    end

    # Get yearbook profile (own or target user's if yearbook_manage)
    post '/api/yearbook/get_my_profile' do
        require_user_with_permission!("yearbook_create")
        require_yearbook_accessible!

        data = parse_request_data(optional_keys: [:target_username])
        target_username = resolve_target_username(data[:target_username])
        profile_data = get_yearbook_profile_data(target_username)

        respond(success: true, profile: profile_data || {})
    end

    # Save yearbook profile (own or target user's if yearbook_manage)
    post '/api/yearbook/save_profile' do
        require_user_with_permission!("yearbook_create")
        require_yearbook_accessible!

        data = parse_request_data(
            required_keys: [:fields],
            optional_keys: [:target_username],
            max_body_length: 16384,
            max_string_length: 8192
        )

        fields = data[:fields]
        assert(fields.is_a?(Hash), "Ungültige Felder")
        username = resolve_target_username(data[:target_username])

        save_yearbook_profile(username, fields)

        respond(success: true, message: "Steckbrief gespeichert")
    end

    # Upload a file for a yearbook field (profile or question); yearbook_manage may pass target_username
    post '/api/yearbook/upload_file' do
        require_user_with_permission!("yearbook_create")
        require_yearbook_accessible!

        file = params[:file]
        field_id = params[:field_id].to_s.strip
        context = params[:context].to_s.strip
        raw_target = params[:target_username].to_s.strip

        assert(file && file[:tempfile], "Keine Datei hochgeladen")
        assert(!field_id.empty? && field_id =~ /\A[a-zA-Z_][a-zA-Z0-9_]*\z/, "Ungültige Feld-ID")
        assert(['profile', 'answer'].include?(context), "Ungültiger Kontext")

        username = resolve_target_username(raw_target.empty? ? nil : raw_target)

        field_config = if context == 'profile'
            yearbook_profile_fields.find { |f| f[:id] == field_id }
        else
            yearbook_questions.find { |q| q[:id] == field_id }
        end
        assert(field_config, "Ungültiges Feld")
        assert(field_config[:type] == 'upload', "Feld ist kein Upload-Feld")

        max_file_size = (field_config[:max_file_size] || 10_000_000).to_i
        max_uploads = (field_config[:max_uploads] || 5).to_i

        file_size = file[:tempfile].size
        assert(file_size > 0, "Leere Datei")
        assert(file_size <= max_file_size, "Datei zu groß (max. #{(max_file_size / 1_000_000.0).ceil} MB)")

        current_uploads = get_yearbook_uploads_for_user(username, context, field_id)
        assert(current_uploads.size < max_uploads, "Maximale Anzahl Uploads (#{max_uploads}) erreicht")

        upload_id = RandomTag.generate(16)
        # Sanitize filename: allow only safe characters, strip directory traversal sequences
        raw_name = File.basename(file[:filename] || 'upload')
        original_filename = raw_name
            .gsub(/[^a-zA-Z0-9._-]/, '_')
            .gsub(/\.{2,}/, '_')   # prevent .. sequences
            .gsub(/^[._-]+/, '')   # strip leading dots/dashes/underscores
        original_filename = 'upload' if original_filename.empty?
        original_filename = original_filename[0, 100]
        mimetype = file[:type] || 'application/octet-stream'

        FileUtils.mkdir_p(YEARBOOK_UPLOAD_PATH)
        dest_path = File.join(YEARBOOK_UPLOAD_PATH, "#{upload_id}_#{original_filename}")
        File.open(dest_path, 'wb') { |f| f.write(file[:tempfile].read) }

        neo4j_query(<<~END_OF_QUERY, { username: username, upload_id: upload_id, original_filename: original_filename, mimetype: mimetype, field_id: field_id, context: context, now: yearbook_timestamp })
            MATCH (u:User {username: $username})
            CREATE (u)-[:HAS_YEARBOOK_UPLOAD]->(up:YearbookUpload {
                id: $upload_id,
                original_filename: $original_filename,
                mimetype: $mimetype,
                field_id: $field_id,
                context: $context,
                created_at: $now
            })
        END_OF_QUERY

        respond(success: true, upload_id: upload_id, filename: original_filename)
    end

    # Download a yearbook upload file
    get '/api/yearbook/file/:upload_id' do
        require_user!
        upload_id = params[:upload_id].to_s.strip
        assert(upload_id =~ /\A[a-zA-Z0-9]+\z/, "Ungültige Datei-ID")

        result = neo4j_query(<<~END_OF_QUERY, {upload_id: upload_id})
            MATCH (u:User)-[:HAS_YEARBOOK_UPLOAD]->(up:YearbookUpload {id: $upload_id})
            RETURN u.username AS owner_username, up.original_filename AS filename, up.mimetype AS mimetype
        END_OF_QUERY
        assert(!result.empty?, "Datei nicht gefunden")

        upload = result.first
        owner_username = upload['owner_username']
        can_access = (@session_user[:username] == owner_username) ||
                     user_has_permission?("yearbook_view") ||
                     user_has_permission?("yearbook_manage")
        assert(can_access, "Keine Berechtigung")

        original_filename = upload['filename']
        file_path = File.join(YEARBOOK_UPLOAD_PATH, "#{upload_id}_#{original_filename}")
        assert(File.exist?(file_path), "Datei nicht gefunden")

        content = File.binread(file_path)
        respond_raw_with_mimetype_and_filename(content, upload['mimetype'] || 'application/octet-stream', original_filename)
    end

    # Delete a yearbook upload
    post '/api/yearbook/delete_upload' do
        require_user!
        require_yearbook_accessible!

        data = parse_request_data(required_keys: [:upload_id])
        upload_id = data[:upload_id].to_s.strip

        result = neo4j_query(<<~END_OF_QUERY, {upload_id: upload_id})
            MATCH (u:User)-[:HAS_YEARBOOK_UPLOAD]->(up:YearbookUpload {id: $upload_id})
            RETURN u.username AS owner_username, up.original_filename AS filename
        END_OF_QUERY
        assert(!result.empty?, "Upload nicht gefunden")

        owner_username = result.first['owner_username']
        original_filename = result.first['filename']
        can_delete = (@session_user[:username] == owner_username) || user_has_permission?("yearbook_manage")
        assert(can_delete, "Keine Berechtigung")

        file_path = File.join(YEARBOOK_UPLOAD_PATH, "#{upload_id}_#{original_filename}")
        File.delete(file_path) if File.exist?(file_path)

        neo4j_query(<<~END_OF_QUERY, {upload_id: upload_id})
            MATCH (up:YearbookUpload {id: $upload_id})
            DETACH DELETE up
        END_OF_QUERY

        respond(success: true)
    end

    # Get uploads for a user
    post '/api/yearbook/get_uploads' do
        require_user!
        require_yearbook_accessible!

        data = parse_request_data(optional_keys: [:target_username, :context, :field_id])
        target_username = (data[:target_username] || @session_user[:username]).to_s.strip
        context = (data[:context] || '').to_s.strip
        field_id = (data[:field_id] || '').to_s.strip

        if target_username != @session_user[:username]
            assert(user_has_permission?("yearbook_view") || user_has_permission?("yearbook_manage"), "Keine Berechtigung")
        end

        if !context.empty? && !field_id.empty?
            assert(context =~ /\A[a-zA-Z]+\z/ && field_id =~ /\A[a-zA-Z_][a-zA-Z0-9_]*\z/, "Ungültige Parameter")
            uploads = get_yearbook_uploads_for_user(target_username, context, field_id)
        else
            uploads_raw = neo4j_query(<<~END_OF_QUERY, {username: target_username})
                MATCH (u:User {username: $username})-[:HAS_YEARBOOK_UPLOAD]->(up:YearbookUpload)
                RETURN up.id AS id, up.original_filename AS filename, up.mimetype AS mimetype,
                       up.field_id AS field_id, up.context AS context
                ORDER BY up.created_at
            END_OF_QUERY
            uploads = uploads_raw.map { |r| { id: r['id'], filename: r['filename'], mimetype: r['mimetype'], field_id: r['field_id'], context: r['context'] } }
        end

        respond(success: true, uploads: uploads)
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
            # Only expose attributed anonymous answers to yearbook_manage users
            attributed_anonymous: has_manage ? data[:attributed_anonymous] : {},
            profiles: data[:profiles],
            questions: data[:questions].map { |q| { id: q[:id], question: q[:question], type: q[:type], anonymous: q[:anonymous], options: q[:options] || [] } },
            allow_delete_all: yearbook_allow_delete_all?
        )
    end

    # Get a specific user's yearbook entry (for yearbook_view or yearbook_manage, or own entry)
    post '/api/yearbook/get_user_entry' do
        require_user!
        require_yearbook_accessible!

        has_view = user_has_permission?("yearbook_view")
        has_manage = user_has_permission?("yearbook_manage")

        data = parse_request_data(required_keys: [:target_username])
        target_username = data[:target_username].to_s.strip

        is_own = (@session_user[:username] == target_username)
        unless is_own || has_view || has_manage
            assert(false, "Keine Berechtigung")
        end

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

        uploads_raw = neo4j_query(<<~END_OF_QUERY, {username: target_username})
            MATCH (u:User {username: $username})-[:HAS_YEARBOOK_UPLOAD]->(up:YearbookUpload)
            RETURN up.id AS id, up.original_filename AS filename, up.mimetype AS mimetype,
                   up.field_id AS field_id, up.context AS context
            ORDER BY up.created_at
        END_OF_QUERY
        uploads = uploads_raw.map { |r| { id: r['id'], filename: r['filename'], mimetype: r['mimetype'], field_id: r['field_id'], context: r['context'] } }

        questions = yearbook_questions.map { |q| {
            id: q[:id], question: q[:question], type: q[:type],
            anonymous: q[:anonymous], options: q[:options] || [],
            max_file_size: q[:max_file_size], max_uploads: q[:max_uploads]
        } }

        # Fetch Schueler assignment for the target user
        schueler_result = neo4j_query(<<~END_OF_QUERY, {username: target_username})
            MATCH (u:User {username: $username})-[:IS_SCHUELER]->(s:Schueler)
            RETURN s.id AS id, s.name AS name
        END_OF_QUERY
        schueler = schueler_result.empty? ? nil : { id: schueler_result.first['id'], name: schueler_result.first['name'] }

        # Fetch the current user's own sent comment for this entry (if viewing someone else's)
        my_sent_comment = nil
        unless is_own || schueler.nil?
            my_comment_result = neo4j_query(<<~END_OF_QUERY, {username: @session_user[:username], schueler_id: schueler[:id]})
                MATCH (u:User {username: $username})-[:WROTE_YEARBOOK_COMMENT]->(c:YearbookComment)-[:ON_YEARBOOK_ENTRY_OF]->(s:Schueler {id: $schueler_id})
                WHERE COALESCE(c.status, 'pending') <> 'removed'
                RETURN c.text AS text
                ORDER BY c.created_at
                LIMIT 1
            END_OF_QUERY
            my_sent_comment = my_comment_result.empty? ? nil : { text: my_comment_result.first['text'] }
        end

        respond(
            success: true,
            username: user_info.first['username'],
            name: user_info.first['name'],
            answers: answers,
            profile: profile_data || {},
            questions: questions,
            profile_fields: yearbook_profile_fields.map { |f| {
                id: f[:id], label: f[:label], type: f[:type],
                max_file_size: f[:max_file_size], max_uploads: f[:max_uploads]
            } },
            uploads: uploads,
            can_manage: has_manage,
            is_own: is_own,
            schueler: schueler,
            my_sent_comment: my_sent_comment
        )
    end

    # Delete a specific user's yearbook entry (yearbook_manage only)
    post '/api/yearbook/delete_entry' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        data = parse_request_data(required_keys: [:target_username])
        target_username = data[:target_username].to_s.strip

        delete_yearbook_entry_for_user(target_username)

        log("Jahrbuch-Eintrag für #{target_username} gelöscht durch #{@session_user[:username]}")
        respond(success: true, message: "Eintrag gelöscht")
    end

    # Delete ALL yearbook entries (requires YEARBOOK_ALLOW_DELETE_ALL credential)
    post '/api/yearbook/delete_all_entries' do
        require_user!
        require_user_with_permission!("yearbook_manage")
        assert(yearbook_allow_delete_all?, "Löschen aller Einträge ist nicht aktiviert")

        all_uploads = neo4j_query("MATCH (up:YearbookUpload) RETURN up.id AS id, up.original_filename AS filename")
        all_uploads.each do |up|
            file_path = File.join(YEARBOOK_UPLOAD_PATH, "#{up['id']}_#{up['filename']}")
            File.delete(file_path) if File.exist?(file_path)
        end

        neo4j_query("MATCH (up:YearbookUpload) DETACH DELETE up")
        neo4j_query("MATCH (y:YearbookEntry) DETACH DELETE y")
        neo4j_query("MATCH (yp:YearbookProfile) DETACH DELETE yp")
        neo4j_query("MATCH (c:YearbookComment) DETACH DELETE c")

        log("Alle Jahrbuch-Einträge gelöscht durch #{@session_user[:username]}")
        respond(success: true, message: "Alle Einträge gelöscht")
    end

    # Get list of Schueler for comment targeting.
    # Returns all Schueler from the credentials list, excluding the current user's own Schueler.
    post '/api/yearbook/get_schueler_list' do
        require_user!
        require_yearbook_accessible!

        ensure_schueler_synced!

        my_schueler_result = neo4j_query(<<~END_OF_QUERY, {username: @session_user[:username]})
            MATCH (u:User {username: $username})-[:IS_SCHUELER]->(s:Schueler)
            RETURN s.id AS id
        END_OF_QUERY
        my_schueler_id = my_schueler_result.empty? ? nil : my_schueler_result.first['id']

        all_schueler = neo4j_query(<<~END_OF_QUERY)
            MATCH (s:Schueler)
            RETURN s.id AS id, s.name AS name
            ORDER BY s.name
        END_OF_QUERY

        list = all_schueler
            .select { |s| s['id'] != my_schueler_id }
            .map { |s| { id: s['id'], name: s['name'] } }

        respond(success: true, schueler: list)
    end

    # Get the Schueler assigned to the current user (or target user if yearbook_manage).
    post '/api/yearbook/get_my_schueler' do
        require_user!

        data = parse_request_data(optional_keys: [:target_username])
        target_username = resolve_target_username(data[:target_username])

        result = neo4j_query(<<~END_OF_QUERY, {username: target_username})
            MATCH (u:User {username: $username})-[:IS_SCHUELER]->(s:Schueler)
            RETURN s.id AS id, s.name AS name
        END_OF_QUERY

        schueler = result.empty? ? nil : { id: result.first['id'], name: result.first['name'] }
        respond(success: true, schueler: schueler)
    end

    # Get the Schueler assigned to any user (yearbook_manage).
    # Used by user.html to display and manage the assignment for a specific user.
    post '/api/yearbook/get_user_schueler' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        ensure_schueler_synced!

        data = parse_request_data(required_keys: [:username])
        target_username = data[:username].to_s.strip

        result = neo4j_query(<<~END_OF_QUERY, {username: target_username})
            MATCH (u:User {username: $username})-[:IS_SCHUELER]->(s:Schueler)
            RETURN s.id AS id, s.name AS name
        END_OF_QUERY
        schueler = result.empty? ? nil : { id: result.first['id'], name: result.first['name'] }

        all_schueler = neo4j_query(<<~END_OF_QUERY)
            MATCH (s:Schueler)
            OPTIONAL MATCH (u:User)-[:IS_SCHUELER]->(s)
            RETURN s.id AS id, s.name AS name, u.username AS assigned_username
            ORDER BY s.name
        END_OF_QUERY
        schueler_list = all_schueler.map { |s|
            { id: s['id'], name: s['name'], assigned_username: s['assigned_username'] }
        }

        respond(success: true, schueler: schueler, schueler_list: schueler_list)
    end

    # Get all Schueler with their assigned users (yearbook_manage).
    # Used by users.html for the full overview tab.
    post '/api/yearbook/get_schueler_assignments' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        ensure_schueler_synced!

        results = neo4j_query(<<~END_OF_QUERY)
            MATCH (s:Schueler)
            OPTIONAL MATCH (u:User)-[:IS_SCHUELER]->(s)
            RETURN s.id AS schueler_id, s.name AS schueler_name,
                   u.username AS username, u.name AS user_name
            ORDER BY s.name
        END_OF_QUERY

        assignments = results.map { |r|
            {
                schueler_id: r['schueler_id'],
                schueler_name: r['schueler_name'],
                username: r['username'],
                user_name: r['user_name']
            }
        }

        respond(success: true, assignments: assignments)
    end

    # Assign a Schueler to a user (yearbook_manage only).
    # Each Schueler can only be linked to one user, and each user to one Schueler.
    post '/api/yearbook/assign_schueler' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        data = parse_request_data(required_keys: [:schueler_id, :username])
        schueler_id = data[:schueler_id].to_s.strip
        target_username = data[:username].to_s.strip

        schueler_exists = neo4j_query(<<~END_OF_QUERY, {id: schueler_id})
            MATCH (s:Schueler {id: $id}) RETURN s.id AS id
        END_OF_QUERY
        assert(!schueler_exists.empty?, "Schüler nicht gefunden")

        user_exists = neo4j_query(<<~END_OF_QUERY, {username: target_username})
            MATCH (u:User {username: $username}) RETURN u.username AS username
        END_OF_QUERY
        assert(!user_exists.empty?, "Benutzer nicht gefunden")

        # Remove any existing IS_SCHUELER link for this Schueler and for this user
        neo4j_query(<<~END_OF_QUERY, {schueler_id: schueler_id})
            MATCH (:User)-[r:IS_SCHUELER]->(s:Schueler {id: $schueler_id})
            DELETE r
        END_OF_QUERY
        neo4j_query(<<~END_OF_QUERY, {username: target_username})
            MATCH (u:User {username: $username})-[r:IS_SCHUELER]->(:Schueler)
            DELETE r
        END_OF_QUERY
        neo4j_query(<<~END_OF_QUERY, {schueler_id: schueler_id, username: target_username})
            MATCH (s:Schueler {id: $schueler_id})
            MATCH (u:User {username: $username})
            CREATE (u)-[:IS_SCHUELER]->(s)
        END_OF_QUERY

        log("Schüler '#{schueler_id}' für #{target_username} zugewiesen durch #{@session_user[:username]}")
        respond(success: true, message: "Schüler zugewiesen")
    end

    # Remove the Schueler assignment for a given Schueler (yearbook_manage only).
    post '/api/yearbook/unassign_schueler' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        data = parse_request_data(required_keys: [:schueler_id])
        schueler_id = data[:schueler_id].to_s.strip

        neo4j_query(<<~END_OF_QUERY, {schueler_id: schueler_id})
            MATCH (:User)-[r:IS_SCHUELER]->(s:Schueler {id: $schueler_id})
            DELETE r
        END_OF_QUERY

        log("Schüler-Zuweisung für '#{schueler_id}' entfernt durch #{@session_user[:username]}")
        respond(success: true, message: "Zuweisung entfernt")
    end

    # Get a minimal list of all active users for the Schueler assignment modal.
    post '/api/yearbook/get_users_for_assignment' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        users = neo4j_query(<<~END_OF_QUERY)
            MATCH (u:User)
            WHERE COALESCE(u.scanner_only, false) = false
              AND COALESCE(u.disabled, false) = false
            RETURN u.username AS username, u.name AS name
            ORDER BY u.name
        END_OF_QUERY

        respond(success: true, users: users.map { |u| { username: u['username'], name: u['name'] } })
    end

    # Post a comment on a Schueler's yearbook entry.
    # The commenter must have yearbook_create permission.
    # New comments start with status 'pending'; the assigned user must approve them.
    post '/api/yearbook/post_comment' do
        require_user!
        require_yearbook_accessible!
        require_user_with_permission!("yearbook_create")

        data = parse_request_data(
            required_keys: [:target_schueler_id, :text],
            max_body_length: 4096,
            max_string_length: 2048
        )

        target_schueler_id = data[:target_schueler_id].to_s.strip
        text = data[:text].to_s.strip[0, MAX_YEARBOOK_COMMENT_LENGTH]
        assert(!text.empty?, "Kommentar darf nicht leer sein")

        commenter_username = @session_user[:username]

        # Prevent commenting on own Schueler entry
        own_schueler = neo4j_query(<<~END_OF_QUERY, {username: commenter_username})
            MATCH (u:User {username: $username})-[:IS_SCHUELER]->(s:Schueler)
            RETURN s.id AS id
        END_OF_QUERY
        if own_schueler.any?
            assert(own_schueler.first['id'] != target_schueler_id, "Du kannst nicht auf deinem eigenen Eintrag kommentieren")
        end

        # Verify target Schueler exists
        target = neo4j_query(<<~END_OF_QUERY, {id: target_schueler_id})
            MATCH (s:Schueler {id: $id})
            RETURN s.id AS id
        END_OF_QUERY
        assert(!target.empty?, "Schüler nicht gefunden")

        # Prevent duplicate comments: block if user already has a non-removed comment for this target
        existing_comment = neo4j_query(<<~END_OF_QUERY, {commenter: commenter_username, schueler_id: target_schueler_id})
            MATCH (commenter:User {username: $commenter})-[:WROTE_YEARBOOK_COMMENT]->(c:YearbookComment)-[:ON_YEARBOOK_ENTRY_OF]->(s:Schueler {id: $schueler_id})
            WHERE COALESCE(c.status, 'pending') <> 'removed'
            RETURN c.id AS id
        END_OF_QUERY
        assert(existing_comment.empty?, "Du hast bereits einen Kommentar an diese Person gesendet")

        comment_id = RandomTag.generate(16)
        neo4j_query(<<~END_OF_QUERY, { commenter: commenter_username, schueler_id: target_schueler_id, comment_id: comment_id, text: text, now: yearbook_timestamp })
            MATCH (commenter:User {username: $commenter})
            MATCH (target:Schueler {id: $schueler_id})
            CREATE (commenter)-[:WROTE_YEARBOOK_COMMENT]->(c:YearbookComment {
                id: $comment_id,
                text: $text,
                created_at: $now,
                status: 'pending'
            })-[:ON_YEARBOOK_ENTRY_OF]->(target)
        END_OF_QUERY

        respond(success: true, message: "Kommentar gespeichert")
    end

    # Get all non-removed comments written by the current user (text + recipient name, no status)
    post '/api/yearbook/get_my_sent_comments' do
        require_user!
        require_yearbook_accessible!
        require_user_with_permission!("yearbook_create")

        username = @session_user[:username]
        results = neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})-[:WROTE_YEARBOOK_COMMENT]->(c:YearbookComment)-[:ON_YEARBOOK_ENTRY_OF]->(s:Schueler)
            WHERE COALESCE(c.status, 'pending') <> 'removed'
            RETURN c.text AS text, c.created_at AS created_at, s.name AS schueler_name
            ORDER BY c.created_at DESC
        END_OF_QUERY

        comments = results.map { |r|
            { text: r['text'], created_at: r['created_at'], schueler_name: r['schueler_name'] }
        }

        respond(success: true, comments: comments)
    end

    # Get comments received on a Schueler entry.
    # Personal use: returns pending and approved comments (not removed).
    # yearbook_manage with target_username: returns ALL comments including removed, with commenter_username.
    post '/api/yearbook/get_received_comments' do
        require_user!
        require_yearbook_accessible!

        data = parse_request_data(optional_keys: [:target_username])
        is_admin_view = !data[:target_username].to_s.strip.empty? && user_has_permission?("yearbook_manage")
        target_username = resolve_target_username(data[:target_username])

        schueler_result = neo4j_query(<<~END_OF_QUERY, {username: target_username})
            MATCH (u:User {username: $username})-[:IS_SCHUELER]->(s:Schueler)
            RETURN s.id AS id
        END_OF_QUERY

        if schueler_result.empty?
            respond(success: true, comments: [])
            return
        end

        schueler_id = schueler_result.first['id']

        if is_admin_view
            results = neo4j_query(<<~END_OF_QUERY, {schueler_id: schueler_id})
                MATCH (commenter:User)-[:WROTE_YEARBOOK_COMMENT]->(c:YearbookComment)-[:ON_YEARBOOK_ENTRY_OF]->(s:Schueler {id: $schueler_id})
                RETURN c.id AS id, c.text AS text, c.created_at AS created_at,
                       COALESCE(c.status, 'pending') AS status,
                       c.removed_at AS removed_at,
                       commenter.name AS commenter_name, commenter.username AS commenter_username
                ORDER BY c.created_at
            END_OF_QUERY
            comments = results.map { |r|
                { id: r['id'], text: r['text'], created_at: r['created_at'],
                  status: r['status'], removed_at: r['removed_at'],
                  commenter_name: r['commenter_name'], commenter_username: r['commenter_username'] }
            }
        else
            results = neo4j_query(<<~END_OF_QUERY, {schueler_id: schueler_id})
                MATCH (commenter:User)-[:WROTE_YEARBOOK_COMMENT]->(c:YearbookComment)-[:ON_YEARBOOK_ENTRY_OF]->(s:Schueler {id: $schueler_id})
                WHERE COALESCE(c.status, 'pending') <> 'removed'
                RETURN c.id AS id, c.text AS text, c.created_at AS created_at,
                       COALESCE(c.status, 'pending') AS status,
                       commenter.name AS commenter_name
                ORDER BY c.created_at
            END_OF_QUERY
            comments = results.map { |r|
                { id: r['id'], text: r['text'], created_at: r['created_at'],
                  status: r['status'], commenter_name: r['commenter_name'] }
            }
        end

        respond(success: true, comments: comments)
    end

    # Approve a pending comment on own Schueler entry (or any entry for yearbook_manage)
    post '/api/yearbook/approve_comment' do
        require_user!
        require_yearbook_accessible!

        data = parse_request_data(required_keys: [:comment_id])
        comment_id = data[:comment_id].to_s.strip

        username = @session_user[:username]

        result = if user_has_permission?("yearbook_manage")
            neo4j_query(<<~END_OF_QUERY, {comment_id: comment_id})
                MATCH (c:YearbookComment {id: $comment_id})
                RETURN c.id AS id
            END_OF_QUERY
        else
            neo4j_query(<<~END_OF_QUERY, {comment_id: comment_id, username: username})
                MATCH (c:YearbookComment {id: $comment_id})-[:ON_YEARBOOK_ENTRY_OF]->(s:Schueler)<-[:IS_SCHUELER]-(u:User {username: $username})
                RETURN c.id AS id
            END_OF_QUERY
        end
        assert(!result.empty?, "Kommentar nicht gefunden oder keine Berechtigung")

        neo4j_query(<<~END_OF_QUERY, {comment_id: comment_id, now: yearbook_timestamp})
            MATCH (c:YearbookComment {id: $comment_id})
            SET c.status = 'approved', c.approved_at = $now
        END_OF_QUERY

        respond(success: true, message: "Kommentar angenommen")
    end

    # Remove a comment from own Schueler entry (soft delete; yearbook_manage can remove any)
    post '/api/yearbook/remove_comment' do
        require_user!
        require_yearbook_accessible!

        data = parse_request_data(required_keys: [:comment_id])
        comment_id = data[:comment_id].to_s.strip

        username = @session_user[:username]

        result = if user_has_permission?("yearbook_manage")
            neo4j_query(<<~END_OF_QUERY, {comment_id: comment_id})
                MATCH (c:YearbookComment {id: $comment_id})
                RETURN c.id AS id
            END_OF_QUERY
        else
            neo4j_query(<<~END_OF_QUERY, {comment_id: comment_id, username: username})
                MATCH (c:YearbookComment {id: $comment_id})-[:ON_YEARBOOK_ENTRY_OF]->(s:Schueler)<-[:IS_SCHUELER]-(u:User {username: $username})
                RETURN c.id AS id
            END_OF_QUERY
        end
        assert(!result.empty?, "Kommentar nicht gefunden oder keine Berechtigung")

        neo4j_query(<<~END_OF_QUERY, {comment_id: comment_id, now: yearbook_timestamp})
            MATCH (c:YearbookComment {id: $comment_id})
            SET c.status = 'removed', c.removed_at = $now
        END_OF_QUERY

        respond(success: true, message: "Kommentar entfernt")
    end

    # Admin: restore a removed comment back to pending state
    post '/api/yearbook/admin_restore_comment' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        data = parse_request_data(required_keys: [:comment_id])
        comment_id = data[:comment_id].to_s.strip

        result = neo4j_query(<<~END_OF_QUERY, {comment_id: comment_id})
            MATCH (c:YearbookComment {id: $comment_id})
            RETURN c.id AS id
        END_OF_QUERY
        assert(!result.empty?, "Kommentar nicht gefunden")

        neo4j_query(<<~END_OF_QUERY, {comment_id: comment_id})
            MATCH (c:YearbookComment {id: $comment_id})
            SET c.status = 'pending'
            REMOVE c.removed_at
        END_OF_QUERY

        respond(success: true, message: "Kommentar wiederhergestellt")
    end

    # Admin: permanently delete a comment
    post '/api/yearbook/admin_delete_comment' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        data = parse_request_data(required_keys: [:comment_id])
        comment_id = data[:comment_id].to_s.strip

        neo4j_query(<<~END_OF_QUERY, {comment_id: comment_id})
            MATCH (c:YearbookComment {id: $comment_id})
            DETACH DELETE c
        END_OF_QUERY

        respond(success: true, message: "Kommentar gelöscht")
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
        non_anon_questions = questions.select { |q| !q[:anonymous] && q[:type] != 'upload' }
        profile_fields = yearbook_profile_fields.select { |f| f[:type] != 'upload' }

        all_usernames = Set.new
        data[:user_answers].each_key { |k| all_usernames << k unless k == '__anonymous' }
        data[:profiles].each { |p| all_usernames << p[:username] }

        csv_string = CSV.generate(col_sep: ';', encoding: 'UTF-8') do |csv|
            header = ['Benutzername', 'Name']
            profile_fields.each { |f| header << f[:label] }
            non_anon_questions.each { |q| header << q[:question] }
            csv << header

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
