require 'base64'
require 'chunky_png'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'zlib'

class Main < Sinatra::Base

    YEARBOOK_TEMPLATE_PATH = '/raw/yearbook_template.json'
    # Per-user personalised templates. Each student who customises their page gets one
    # JSON file here (named after their username). When present, it overrides the global
    # variant for that student at render time.
    YEARBOOK_USER_TEMPLATE_DIR = '/raw/yearbook_user_templates'
    YEARBOOK_PDFME_NODE_MODULES = '/opt/pdfme/node_modules'
    YEARBOOK_PDFME_SCRIPT = '/src/scripts/generate_pdf.js'

    # Allowed username characters for route params. Usernames are normally [a-z0-9_-] but
    # some accounts use their email address as username, so "@", "." and "+" are allowed
    # too. Usernames are only ever used as parameterized Neo4j query values (never string-
    # interpolated), so this is purely a sanity/URL-safety guard.
    YEARBOOK_USERNAME_FORMAT = /\A[a-zA-Z0-9._@+-]+\z/

    # Auto-discovered admin-provided files. Drop fonts / images into these
    # directories and they appear in the designer + are baked into PDFs.
    YEARBOOK_FONTS_DIR = '/src/static/include/yearbook_fonts'
    YEARBOOK_ASSETS_DIR = '/src/static/include/yearbook_assets'
    YEARBOOK_BACKGROUNDS_DIR = '/src/static/include/yearbook_backgrounds'
    YEARBOOK_FONT_EXTENSIONS = %w[.ttf .otf].freeze
    YEARBOOK_ASSET_EXTENSIONS = %w[.png .jpg .jpeg .gif .webp].freeze
    YEARBOOK_BACKGROUND_EXTENSIONS = %w[.pdf].freeze

    YEARBOOK_DEFAULT_ACCENT_COLOR = '#0d6efd'
    # Schema entries whose name starts with this prefix have their colour properties
    # rewritten to the student's accent colour at render time (legacy mechanism, kept
    # for back-compat — the hex-substitution path below is the recommended way now).
    YEARBOOK_ACCENT_NAME_PREFIX = '__accent_'
    YEARBOOK_ACCENT_PROPERTIES = %w[color fontColor borderColor backgroundColor].freeze
    # Default sentinel colour for the hex-substitution mechanism. Admins can override
    # per-variant via accent_placeholder_hex.
    YEARBOOK_DEFAULT_ACCENT_PLACEHOLDER = '#FF00FF'

    # Synthetic catalog field that pulls every non-empty profile field + non-anonymous
    # text/textarea answer into a single multi-line text element. Placed once on the
    # canvas, it collapses gaps automatically so missing entries don't leave holes.
    YEARBOOK_BIO_BLOCK_NAME = '__bio_block'

    # A4 portrait. Padding is *intentionally* [0,0,0,0]: pdfme's dynamic-layout pass uses
    # padding[0] to compute each element's localY (`position.y - paddingTop`). With a
    # non-zero top padding, any element placed at y < paddingTop (e.g. a full-page accent
    # background at (0, 0)) yields a negative localY, which sends currentPageIndex to -1
    # and crashes placeRowsOnPages with "Cannot read properties of undefined (reading
    # 'push')". Keeping padding at zero lets admins place elements anywhere on the canvas.
    YEARBOOK_DEFAULT_BASE_PDF = {
        'width' => 210,
        'height' => 297,
        'padding' => [0, 0, 0, 0]
    }

    # Build the catalog of fields an admin can place on the page.
    # Each entry: { name, label, type ("text" | "image"), source ("profile" | "answer" | "meta"), field_id }
    def yearbook_template_field_catalog
        fields = []

        fields << {
            'name' => 'display_name',
            'label' => 'Name',
            'type' => 'text',
            'source' => 'meta',
            'field_id' => 'display_name'
        }

        fields << {
            'name' => YEARBOOK_BIO_BLOCK_NAME,
            'label' => 'Steckbrief-Block (alle ausgefüllten Felder)',
            'type' => 'text',
            'source' => 'meta',
            'field_id' => YEARBOOK_BIO_BLOCK_NAME
        }

        yearbook_profile_fields.each do |f|
            next unless f[:id] =~ /\A[a-zA-Z_][a-zA-Z0-9_]*\z/
            fields << {
                'name' => f[:id],
                'label' => f[:label].to_s,
                'type' => (f[:type] == 'upload' ? 'image' : 'text'),
                'source' => 'profile',
                'field_id' => f[:id]
            }
        end

        yearbook_questions.each do |q|
            next unless q[:id] =~ /\A[a-zA-Z_][a-zA-Z0-9_]*\z/
            # Anonymous questions don't make sense on a per-student page.
            next if q[:anonymous]
            next if q[:type] == 'multiple_choice' # would need joining; skip for now
            fields << {
                'name' => q[:id],
                'label' => q[:question].to_s,
                'type' => (q[:type] == 'upload' ? 'image' : 'text'),
                'source' => 'answer',
                'field_id' => q[:id]
            }
        end

        fields << {
            'name' => 'comments',
            'label' => 'Kommentare (gesammelt)',
            'type' => 'text',
            'source' => 'meta',
            'field_id' => 'comments'
        }

        fields
    end

    def default_yearbook_template
        { 'basePdf' => YEARBOOK_DEFAULT_BASE_PDF, 'schemas' => [[]] }
    end

    # ----- font / asset auto-discovery -------------------------------------

    # Sorted list of font filenames in YEARBOOK_FONTS_DIR (basenames only).
    def yearbook_font_files
        return [] unless File.directory?(YEARBOOK_FONTS_DIR)
        Dir.entries(YEARBOOK_FONTS_DIR)
            .select { |f| YEARBOOK_FONT_EXTENSIONS.include?(File.extname(f).downcase) }
            .reject { |f| f.start_with?('.') }
            .sort
    end

    # Sorted list of asset image filenames in YEARBOOK_ASSETS_DIR.
    def yearbook_asset_files
        return [] unless File.directory?(YEARBOOK_ASSETS_DIR)
        Dir.entries(YEARBOOK_ASSETS_DIR)
            .select { |f| YEARBOOK_ASSET_EXTENSIONS.include?(File.extname(f).downcase) }
            .reject { |f| f.start_with?('.') }
            .sort
    end

    # Sorted list of PDF background filenames. An admin drops a PDF in this directory
    # and can then pick it as the basePdf of a variant in the designer.
    def yearbook_background_files
        return [] unless File.directory?(YEARBOOK_BACKGROUNDS_DIR)
        Dir.entries(YEARBOOK_BACKGROUNDS_DIR)
            .select { |f| YEARBOOK_BACKGROUND_EXTENSIONS.include?(File.extname(f).downcase) }
            .reject { |f| f.start_with?('.') }
            .sort
    end

    # Strip the extension from a font filename to get the PostScript-ish name pdfme uses
    # in its font registry (e.g. "Roboto-Bold.ttf" -> "Roboto-Bold").
    def yearbook_font_name_for(filename)
        File.basename(filename, File.extname(filename))
    end

    # Build { fontName => base64-of-binary } for shipping to Node. The first font (sorted)
    # is the fallback — pdfme requires exactly one font with fallback=true. If no admin
    # fonts are present we return an empty hash; the Node script then leaves
    # options.font undefined and pdfme falls back to its bundled Roboto.
    def yearbook_fonts_payload
        files = yearbook_font_files
        return {} if files.empty?
        files.each_with_object({}) do |filename, h|
            name = yearbook_font_name_for(filename)
            path = File.join(YEARBOOK_FONTS_DIR, filename)
            next unless File.file?(path)
            h[name] = {
                'data' => Base64.strict_encode64(File.binread(path)),
                'fallback' => (h.empty?)
            }
        end
    end

    # ----- variant set (one yearbook page can have many template variants) ------

    def default_yearbook_variant
        {
            'id' => 'default',
            'name' => 'Standard',
            'photo_count' => nil, # nil = matches every student
            'template' => default_yearbook_template
        }
    end

    def default_yearbook_variant_set
        { 'version' => 2, 'variants' => [default_yearbook_variant] }
    end

    def sanitize_yearbook_variant(v)
        return default_yearbook_variant unless v.is_a?(Hash)
        tpl = v['template'].is_a?(Hash) ? v['template'] : default_yearbook_template
        tpl['basePdf'] ||= YEARBOOK_DEFAULT_BASE_PDF
        # See YEARBOOK_DEFAULT_BASE_PDF for the rationale on forcing zero padding.
        if tpl['basePdf'].is_a?(Hash) && tpl['basePdf']['width']
            tpl['basePdf']['padding'] = [0, 0, 0, 0]
        end
        tpl['schemas'] = [[]] unless tpl['schemas'].is_a?(Array) && !tpl['schemas'].empty?
        # Page 0 = Steckbrief (always exactly one page). Page 1+ = comment pages, the
        # last of which is duplicated at render time to spill all of a student's comments.
        # Auto-append a blank Page 1 if a legacy variant only has the Steckbrief — the
        # admin can decorate it later.
        tpl['schemas'] << [] while tpl['schemas'].length < 2
        # yearbook_blocks lives on the variant (not inside the template) so pdfme's
        # Designer never sees it and can't strip it during schema validation.
        blocks = v['yearbook_blocks'].is_a?(Hash) ? v['yearbook_blocks'] : {}

        # recolor_images: { "<image schema name>" => true } for image elements the admin
        # explicitly opted in to accent-colour replacement. Stored on the variant (not in
        # the template) for the same reason as yearbook_blocks. Uploaded student photos are
        # never listed here, so they are never recoloured.
        recolor = {}
        if v['recolor_images'].is_a?(Hash)
            v['recolor_images'].each { |k, val| recolor[k.to_s] = true if val }
        end

        # background_pdf is a *filename* (not embedded data). Ruby reads the file at render
        # time and substitutes it into basePdf. Keeps saved variants small even when the
        # admin uses a multi-MB PDF as the page background.
        bg = v['background_pdf'].to_s.strip
        bg = nil unless bg =~ /\A[a-zA-Z0-9._-]+\.pdf\z/i && yearbook_background_files.include?(bg)

        # accent_placeholder_hex is the sentinel colour that the render path swaps with
        # the student's actual accent colour. Validated as #RRGGBB.
        placeholder = v['accent_placeholder_hex'].to_s
        placeholder = YEARBOOK_DEFAULT_ACCENT_PLACEHOLDER unless placeholder =~ /\A#[0-9A-Fa-f]{6}\z/

        {
            'id'                     => (v['id'].is_a?(String) && !v['id'].empty?) ? v['id'] : "v_#{RandomTag.generate(8)}",
            'name'                   => (v['name'] || 'Unbenannt').to_s,
            'photo_count'            => (v['photo_count'].is_a?(Integer) ? v['photo_count'] : nil),
            'template'               => tpl,
            'yearbook_blocks'        => blocks,
            'recolor_images'         => recolor,
            'background_pdf'         => bg,
            'accent_placeholder_hex' => placeholder
        }
    end

    # Load the full variant set, transparently migrating older single-template files
    # ({basePdf, schemas}) so existing installations keep working.
    def load_yearbook_variant_set
        return default_yearbook_variant_set unless File.exist?(YEARBOOK_TEMPLATE_PATH)
        begin
            data = JSON.parse(File.read(YEARBOOK_TEMPLATE_PATH))
            return default_yearbook_variant_set unless data.is_a?(Hash)

            # Legacy format: {basePdf, schemas} -> wrap as a single variant.
            if !data['variants'].is_a?(Array) && data['schemas'].is_a?(Array)
                return {
                    'version' => 2,
                    'variants' => [sanitize_yearbook_variant({
                        'id' => 'default',
                        'name' => 'Standard',
                        'photo_count' => nil,
                        'template' => data
                    })]
                }
            end

            variants = (data['variants'] || []).map { |v| sanitize_yearbook_variant(v) }
            variants = [default_yearbook_variant] if variants.empty?
            { 'version' => 2, 'variants' => variants }
        rescue => e
            debug_error "Failed to read yearbook template: #{e.message}"
            default_yearbook_variant_set
        end
    end

    # ----- per-user personalised templates --------------------------------

    # Whether students may individualise their own yearbook page. Defaults to enabled;
    # admins can switch it off via the YEARBOOK_USER_CUSTOMIZATION_ENABLED credential.
    def yearbook_user_customization_enabled?
        return YEARBOOK_USER_CUSTOMIZATION_ENABLED if defined?(YEARBOOK_USER_CUSTOMIZATION_ENABLED)
        true
    end

    # Page guard for the personalisation designer: needs login plus either the create
    # (own page) or manage (someone else's page) permission.
    def site_for_yearbook_personalize!
        unless user_logged_in?
            redirect "#{WEB_ROOT}/no_permission"
            return
        end
        unless user_has_permission?("yearbook_create") || user_has_permission?("yearbook_manage")
            redirect "#{WEB_ROOT}/no_permission"
        end
    end

    # Resolve who a personalisation request targets and authorise it: editing your own
    # page needs yearbook_create; editing someone else's needs yearbook_manage (enforced
    # by resolve_target_username). Returns the effective username.
    def authorize_personalize_target!(target_username)
        t = target_username.to_s.strip
        if t.empty?
            require_user_with_permission!("yearbook_create")
            return @session_user[:username]
        end
        resolve_target_username(t)
    end

    def user_yearbook_template_path(username)
        u = username.to_s.strip
        assert(!u.empty?, "Ungültiger Benutzername")
        # Usernames may contain characters that aren't filesystem-safe (e.g. email-style
        # usernames with "@" and "."). Hash the username so the filename is always safe and
        # free of path-traversal risk, regardless of the allowed username charset.
        File.join(YEARBOOK_USER_TEMPLATE_DIR, "#{Digest::SHA256.hexdigest(u)}.json")
    end

    # Load a user's personalised template, or nil if they haven't customised their page.
    def load_user_yearbook_template(username)
        path = user_yearbook_template_path(username)
        return nil unless File.exist?(path)
        begin
            data = JSON.parse(File.read(path))
            return nil unless data.is_a?(Hash) && data['template'].is_a?(Hash)
            tpl = data['template']
            tpl['basePdf'] ||= YEARBOOK_DEFAULT_BASE_PDF
            if tpl['basePdf'].is_a?(Hash) && tpl['basePdf']['width']
                tpl['basePdf']['padding'] = [0, 0, 0, 0]
            end
            tpl['schemas'] = [[]] unless tpl['schemas'].is_a?(Array) && !tpl['schemas'].empty?
            bg = data['background_pdf'].to_s.strip
            bg = nil unless bg =~ /\A[a-zA-Z0-9._-]+\.pdf\z/i && yearbook_background_files.include?(bg)
            { 'template' => tpl, 'background_pdf' => bg, 'updated_at' => data['updated_at'] }
        rescue => e
            debug_error "Failed to read user yearbook template for #{username}: #{e.message}"
            nil
        end
    end

    def save_user_yearbook_template(username, template, background_pdf)
        assert(template.is_a?(Hash), "Ungültige Vorlage")
        tpl = {}
        tpl['basePdf'] = YEARBOOK_DEFAULT_BASE_PDF
        tpl['schemas'] = (template['schemas'].is_a?(Array) && !template['schemas'].empty?) ? template['schemas'] : [[]]

        bg = background_pdf.to_s.strip
        bg = nil unless bg =~ /\A[a-zA-Z0-9._-]+\.pdf\z/i && yearbook_background_files.include?(bg)

        payload = {
            'version' => 1,
            'template' => tpl,
            'background_pdf' => bg,
            'updated_at' => yearbook_timestamp
        }
        FileUtils.mkdir_p(YEARBOOK_USER_TEMPLATE_DIR)
        File.write(user_yearbook_template_path(username), JSON.pretty_generate(payload))
    end

    def delete_user_yearbook_template(username)
        path = user_yearbook_template_path(username)
        File.delete(path) if File.exist?(path)
    end

    # Overwrite the `content` of every catalog-field schema entry with the user's current
    # data. Custom elements (assets, shapes, manually typed text, expanded block children)
    # keep their content. Used both for the designer seed and when re-opening a saved
    # personal template so placed data fields always show fresh values.
    def refresh_catalog_content!(template, username)
        values = build_yearbook_inputs_for_user(username, template)
        value_map = values ? (values.first || {}) : {}
        (template['schemas'] || []).each do |page|
            next unless page.is_a?(Array)
            page.each do |entry|
                next unless entry.is_a?(Hash)
                name = entry['name']
                entry['content'] = value_map[name] if value_map.key?(name)
            end
        end
        template
    end

    # Catalog of placeable fields enriched with the target user's current value, so the
    # personalisation sidebar can insert a field that already shows the student's data.
    def yearbook_template_field_values_for_user(username)
        catalog = yearbook_template_field_catalog
        fake_template = { 'schemas' => [catalog.map { |f| { 'name' => f['name'] } }] }
        values = build_yearbook_inputs_for_user(username, fake_template)
        value_map = values ? (values.first || {}) : {}
        catalog.map { |f| f.merge('value' => value_map[f['name']].to_s) }
    end

    # Build the initial personalised template for a user from the variant they would
    # otherwise receive: accent colour applied, blocks expanded into concrete text, and
    # the student's current data baked into the field contents so the designer shows a
    # faithful preview that they can rearrange.
    def build_baked_personal_seed(username, variant_set)
        variant = pick_yearbook_variant_for_user(username, variant_set)
        return nil unless variant

        profile = get_yearbook_profile_data(username) || {}
        answer_rows = neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})-[:HAS_YEARBOOK_ENTRY]->(y:YearbookEntry)
            RETURN y.question_id AS question_id, y.answer AS answer
        END_OF_QUERY
        answers = answer_rows.each_with_object({}) { |r, h| h[r['question_id']] = r['answer'] }
        comments = yearbook_comments_for_user(username)

        accent = yearbook_accent_color_for_user(username)
        base_template = apply_accent_color_to_template(variant['template'], accent, variant['accent_placeholder_hex'])
        # Bake the recoloured images into the seed so the personalised page shows (and keeps)
        # the accent-replaced images even though it renders statically.
        recolor_marked_images!(base_template, variant['recolor_images'], variant['accent_placeholder_hex'], accent)

        blocks_config = variant['yearbook_blocks'] || {}
        any_include_pending = blocks_config.values.any? { |c| c.is_a?(Hash) && c['kind'] == 'comments' && c['include_pending'] }
        visible_comments = visible_comments_for_block(comments, any_include_pending)

        pages = base_template['schemas'] || [[]]
        comments_idx = 0
        expanded_pages = pages.map do |page|
            expanded, next_idx = expand_page_blocks(page, blocks_config, profile, answers, visible_comments, comments_idx)
            comments_idx = next_idx if next_idx > comments_idx
            expanded
        end

        seed_template = { 'basePdf' => YEARBOOK_DEFAULT_BASE_PDF, 'schemas' => expanded_pages }
        refresh_catalog_content!(seed_template, username)
        { 'template' => seed_template, 'background_pdf' => variant['background_pdf'] }
    end

    # Build pdfme jobs from a user's personalised template. The personalised template is a
    # normal pdfme template: catalog fields keep updating with live data (via inputs),
    # while custom elements and baked block text stay static (forced readOnly).
    def build_personal_yearbook_jobs(username, personal)
        user_info = neo4j_query(<<~END_OF_QUERY, {username: username}).first
            MATCH (u:User {username: $username})
            RETURN u.username AS username
        END_OF_QUERY
        return [] unless user_info

        base_template = JSON.parse(JSON.dump(personal['template'] || {}))
        base_template['basePdf'] ||= YEARBOOK_DEFAULT_BASE_PDF
        apply_background_pdf_to_template!(base_template, personal['background_pdf'])

        catalog_names = yearbook_template_field_catalog.map { |f| f['name'] }
        pages = base_template['schemas'] || []
        return [] if pages.empty?

        jobs = []
        pages.each do |page_schemas|
            page_template = base_template.dup
            page_template['schemas'] = [page_schemas]
            force_static_schemas_readonly!(page_template, catalog_names)
            inputs = build_yearbook_inputs_for_user(username, page_template)
            jobs << { 'template' => page_template, 'inputs' => inputs } if inputs
        end
        jobs
    end

    # ----- per-user state stored on the User node -------------------------

    def yearbook_photo_count_for_user(username)
        r = neo4j_query(<<~END_OF_QUERY, {username: username}).first
            MATCH (u:User {username: $username})-[:HAS_YEARBOOK_UPLOAD]->(up:YearbookUpload)
            WHERE up.mimetype STARTS WITH 'image/'
            RETURN count(up) AS cnt
        END_OF_QUERY
        r ? r['cnt'].to_i : 0
    end

    def yearbook_pinned_variant_id(username)
        r = neo4j_query(<<~END_OF_QUERY, {username: username}).first
            MATCH (u:User {username: $username})
            RETURN u.yearbook_template_variant AS v
        END_OF_QUERY
        r ? r['v'] : nil
    end

    def yearbook_accent_color_for_user(username)
        r = neo4j_query(<<~END_OF_QUERY, {username: username}).first
            MATCH (u:User {username: $username})
            RETURN u.yearbook_accent_color AS c
        END_OF_QUERY
        color = r && r['c']
        return YEARBOOK_DEFAULT_ACCENT_COLOR unless color.is_a?(String) && color =~ /\A#[0-9A-Fa-f]{6}\z/
        color
    end

    # Pick the most appropriate variant for a user. Order:
    #   1. Admin-pinned variant (if it still exists)
    #   2. Variants whose photo_count matches the user's actual upload count
    #   3. Variants without a photo_count constraint (fallback / "any" variants)
    #   4. First variant defined
    # If multiple variants qualify, the choice is a deterministic pseudo-random pick keyed
    # on the username so re-renders stay stable.
    def pick_yearbook_variant_for_user(username, variant_set)
        variants = (variant_set['variants'] || [])
        return nil if variants.empty?

        pinned = yearbook_pinned_variant_id(username)
        if pinned
            hit = variants.find { |v| v['id'] == pinned }
            return hit if hit
        end

        pc = yearbook_photo_count_for_user(username)
        matching = variants.select { |v| v['photo_count'].is_a?(Integer) && v['photo_count'] == pc }
        matching = variants.select { |v| v['photo_count'].nil? } if matching.empty?
        matching = variants if matching.empty?

        idx = Digest::SHA256.hexdigest(username).to_i(16) % matching.size
        matching[idx]
    end

    # Walk a template and inject the student's accent colour in two ways:
    #   1. Legacy: every schema entry whose `name` starts with __accent_ has its
    #      colour-like properties rewritten.
    #   2. Hex substitution: any colour-like property whose value equals the variant's
    #      placeholder hex (e.g. #FF00FF by default) gets rewritten — admins just pick
    #      that colour in pdfme's normal colour picker, no special naming required.
    # Returns a deep copy so the original variant set isn't mutated for the next render.
    def apply_accent_color_to_template(template, color, placeholder_hex)
        cloned = JSON.parse(JSON.dump(template))
        placeholder = (placeholder_hex || YEARBOOK_DEFAULT_ACCENT_PLACEHOLDER).to_s.downcase
        (cloned['schemas'] || []).each do |page|
            next unless page.is_a?(Array)
            page.each do |entry|
                next unless entry.is_a?(Hash)
                name_match = entry['name'].is_a?(String) && entry['name'].start_with?(YEARBOOK_ACCENT_NAME_PREFIX)
                YEARBOOK_ACCENT_PROPERTIES.each do |prop|
                    next unless entry.key?(prop)
                    val = entry[prop].to_s.downcase
                    if name_match || val == placeholder
                        entry[prop] = color
                    end
                end
            end
        end
        cloned
    end

    # Replace the sentinel/placeholder colour inside image elements that the admin opted in
    # to (via recolor_map) with the student's accent colour. Only PNG data-URL images are
    # processed; everything else (incl. uploaded JPEG/other photos) is left untouched.
    # Mutates the template in place.
    def recolor_marked_images!(template, recolor_map, sentinel_hex, accent_color)
        return template unless recolor_map.is_a?(Hash) && !recolor_map.empty?
        (template['schemas'] || []).each do |page|
            next unless page.is_a?(Array)
            page.each do |entry|
                next unless entry.is_a?(Hash)
                next unless recolor_map[entry['name']]
                content = entry['content'].to_s
                next unless content.start_with?('data:image/png')
                recolored = recolor_png_data_url(content, sentinel_hex, accent_color)
                entry['content'] = recolored if recolored
            end
        end
        template
    end

    # Recolour a PNG data URL: every pixel whose RGB exactly matches sentinel_hex becomes
    # accent_hex (alpha preserved). Returns a new data URL, or nil on failure.
    def recolor_png_data_url(data_url, sentinel_hex, accent_hex)
        b64 = data_url.sub(/\Adata:image\/png;base64,/, '')
        bytes = Base64.decode64(b64)
        img = ChunkyPNG::Image.from_blob(bytes)

        sentinel = ChunkyPNG::Color.from_hex(normalize_hex_for_chunky(sentinel_hex, YEARBOOK_DEFAULT_ACCENT_PLACEHOLDER))
        accent = ChunkyPNG::Color.from_hex(normalize_hex_for_chunky(accent_hex, YEARBOOK_DEFAULT_ACCENT_COLOR))
        s_r = ChunkyPNG::Color.r(sentinel); s_g = ChunkyPNG::Color.g(sentinel); s_b = ChunkyPNG::Color.b(sentinel)
        a_r = ChunkyPNG::Color.r(accent);   a_g = ChunkyPNG::Color.g(accent);   a_b = ChunkyPNG::Color.b(accent)

        img.pixels.map! do |p|
            if ChunkyPNG::Color.r(p) == s_r && ChunkyPNG::Color.g(p) == s_g && ChunkyPNG::Color.b(p) == s_b
                ChunkyPNG::Color.rgba(a_r, a_g, a_b, ChunkyPNG::Color.a(p))
            else
                p
            end
        end

        "data:image/png;base64,#{Base64.strict_encode64(img.to_blob)}"
    rescue => e
        debug_error "recolor_png_data_url failed: #{e.message}"
        nil
    end

    def normalize_hex_for_chunky(hex, fallback)
        h = hex.to_s.strip
        h = fallback unless h =~ /\A#[0-9A-Fa-f]{6}\z/
        h
    end

    # Build the multi-line text for the synthetic Steckbrief-Block. Profile fields come
    # first in config order, then non-anonymous text/textarea answers in config order.
    # Empty values are dropped, so consecutive non-empty fields close any gaps naturally.
    def build_bio_block_text(profile, answers)
        lines = []
        yearbook_profile_fields.each do |f|
            next if f[:type] == 'upload'
            v = profile[f[:id]].to_s.strip
            next if v.empty?
            lines << "#{f[:label]}: #{v}"
        end
        yearbook_questions.each do |q|
            next if q[:anonymous]
            next unless q[:type] == 'text' || q[:type] == 'textarea'
            raw = answers[q[:id]].to_s.strip
            next if raw.empty?
            lines << "#{q[:question]} #{raw}"
        end
        lines.join("\n")
    end

    # ----- field blocks (admin-configured, per-block field picker) ----------
    #
    # Each placeholder schema entry whose `name` appears in template['yearbook_blocks']
    # gets expanded to N text schemas at render time. Empty entries are dropped, so
    # the visible content closes any gaps.
    #
    # Block config shape:
    #   "yearbook_blocks": {
    #     "<schema-name>": {
    #       "kind": "fields" | "comments",
    #       # fields-kind:
    #       "fields": ["nickname", "life_motto", "quote"],
    #       "show_labels": true,
    #       "label_inline": false,
    #       "label_font_name": "Roboto-Bold",   # optional
    #       "value_font_name": "Roboto-Regular",
    #       # comments-kind:
    #       "include_pending": false,
    #       "show_author": true,
    #       "author_font_name": "Roboto-Bold",
    #       "font_name": "Roboto-Regular",
    #       # both kinds:
    #       "font_size": 11,
    #       "line_height": 1.4,
    #       "entry_gap_mm": 1
    #     }
    #   }

    # Single source of truth for converting points to mm (matches pdfme's pt2mm).
    PT_TO_MM = 0.352778

    # Fields the admin can pick for a "fields" block: profile fields + non-anonymous
    # text/textarea questions. Upload fields are excluded — those become image elements,
    # not text lines.
    def yearbook_block_field_options
        out = []
        yearbook_profile_fields.each do |f|
            next if f[:type] == 'upload'
            out << { 'id' => f[:id], 'label' => f[:label].to_s, 'source' => 'profile' }
        end
        yearbook_questions.each do |q|
            next if q[:anonymous]
            next unless q[:type] == 'text' || q[:type] == 'textarea'
            out << { 'id' => q[:id], 'label' => q[:question].to_s, 'source' => 'answer' }
        end
        out
    end

    def yearbook_block_field_label(field_id)
        f = yearbook_profile_fields.find { |x| x[:id] == field_id }
        return f[:label].to_s if f
        q = yearbook_questions.find { |x| x[:id] == field_id }
        return q[:question].to_s if q
        field_id.to_s
    end

    def yearbook_block_field_value(field_id, profile, answers)
        v = profile[field_id]
        return v.to_s.strip if v && !v.to_s.strip.empty?
        raw = answers[field_id].to_s.strip
        # Multiple-choice answers come in as JSON arrays — flatten for display.
        begin
            parsed = JSON.parse(raw)
            raw = parsed.join(', ') if parsed.is_a?(Array)
        rescue
        end
        raw
    end

    # Fetch non-removed comments for a user's Schueler, oldest first.
    def yearbook_comments_for_user(username)
        schueler = neo4j_query(<<~END_OF_QUERY, {username: username}).first
            MATCH (u:User {username: $username})-[:IS_SCHUELER]->(s:Schueler)
            RETURN s.id AS id
        END_OF_QUERY
        return [] unless schueler && schueler['id']

        rows = neo4j_query(<<~END_OF_QUERY, {schueler_id: schueler['id']})
            MATCH (commenter:User)-[:WROTE_YEARBOOK_COMMENT]->(c:YearbookComment)-[:ON_YEARBOOK_ENTRY_OF]->(s:Schueler {id: $schueler_id})
            WHERE COALESCE(c.status, 'pending') <> 'removed'
            OPTIONAL MATCH (commenter)-[:IS_SCHUELER]->(commenter_s:Schueler)
            RETURN c.text AS text,
                   COALESCE(c.status, 'pending') AS status,
                   COALESCE(commenter_s.name, commenter.name) AS commenter_name
            ORDER BY c.created_at
        END_OF_QUERY
        rows.map { |r| { 'text' => r['text'].to_s, 'status' => r['status'], 'commenter_name' => r['commenter_name'].to_s } }
    end

    # Estimate the rendered height of a text element in mm. pdfme wraps long lines, so we
    # also count an extra line for every ~chars_per_line characters in a line.
    def estimate_text_height_mm(content, font_size_pt, line_height_factor, width_mm)
        return 0.0 if content.to_s.empty?
        line_h = font_size_pt * line_height_factor * PT_TO_MM
        # Rough char width estimate: ~half the font size in pt, converted to mm.
        avg_char_width_mm = font_size_pt * 0.5 * PT_TO_MM
        chars_per_line = [(width_mm.to_f / [avg_char_width_mm, 0.01].max).floor, 1].max
        lines = content.to_s.split("\n").sum do |row|
            row.empty? ? 1 : (row.length / chars_per_line.to_f).ceil
        end
        [line_h * lines, line_h].max
    end

    def estimate_text_width_mm(content, font_size_pt)
        content.to_s.length * font_size_pt * 0.5 * PT_TO_MM
    end

    def make_block_text_schema(x, y, width, height, font_name, font_size, content, color, alignment, line_height)
        s = {
            'name' => "_blockchild_#{RandomTag.generate(8)}",
            'type' => 'text',
            'position' => { 'x' => x, 'y' => y },
            'width' => width,
            'height' => height,
            'fontSize' => font_size,
            'fontColor' => color || '#000000',
            'alignment' => alignment || 'left',
            'lineHeight' => line_height,
            'content' => content.to_s,
            'readOnly' => true
        }
        s['fontName'] = font_name if font_name && !font_name.to_s.empty?
        s
    end

    def render_fields_block(block, config, profile, answers)
        out = []
        pos = block['position'] || { 'x' => 0, 'y' => 0 }
        x = pos['x'].to_f
        y_start = pos['y'].to_f
        max_y = y_start + block['height'].to_f
        width = block['width'].to_f

        font_size = (config['font_size'] || block['fontSize'] || 11).to_f
        line_height = (config['line_height'] || 1.4).to_f
        entry_gap = (config['entry_gap_mm'] || 1).to_f
        value_font = config['value_font_name'] || config['font_name'] || block['fontName']
        label_font = config['label_font_name'] || value_font
        color = block['fontColor'] || '#000000'
        alignment = block['alignment'] || 'left'
        show_labels = config['show_labels'] != false
        inline = config['label_inline'] == true

        y = y_start
        (config['fields'] || []).each do |fid|
            value = yearbook_block_field_value(fid, profile, answers)
            next if value.empty?
            label = yearbook_block_field_label(fid)

            if show_labels && inline
                # Two adjacent text elements on the same Y line: "Label: " in label_font,
                # value in value_font. A single text element can't mix font weights, so
                # we measure the label width and place value to its right.
                label_text = "#{label}: "
                label_w = [estimate_text_width_mm(label_text, font_size), width].min
                # Leave at least some room for the value; if the label is wider than the
                # block, drop back to two stacked lines.
                if label_w >= width - 5
                    label_with_colon = "#{label}:"
                    label_h = estimate_text_height_mm(label_with_colon, font_size, line_height, width)
                    value_h = estimate_text_height_mm(value, font_size, line_height, width)
                    break if y + label_h + value_h > max_y + 0.5
                    out << make_block_text_schema(x, y, width, label_h, label_font, font_size, label_with_colon, color, alignment, line_height)
                    y += label_h
                    out << make_block_text_schema(x, y, width, value_h, value_font, font_size, value, color, alignment, line_height)
                    y += value_h + entry_gap
                else
                    value_w = width - label_w
                    row_h = [estimate_text_height_mm(label_text, font_size, line_height, label_w),
                             estimate_text_height_mm(value, font_size, line_height, value_w)].max
                    break if y + row_h > max_y + 0.5
                    out << make_block_text_schema(x, y, label_w, row_h, label_font, font_size, label_text, color, alignment, line_height)
                    out << make_block_text_schema(x + label_w, y, value_w, row_h, value_font, font_size, value, color, alignment, line_height)
                    y += row_h + entry_gap
                end
            elsif show_labels
                # Label on its own line above the value. Label ends with a colon so the
                # visual relationship to its answer stays clear.
                label_with_colon = "#{label}:"
                label_h = estimate_text_height_mm(label_with_colon, font_size, line_height, width)
                value_h = estimate_text_height_mm(value, font_size, line_height, width)
                break if y + label_h + value_h > max_y + 0.5
                out << make_block_text_schema(x, y, width, label_h, label_font, font_size, label_with_colon, color, alignment, line_height)
                y += label_h
                out << make_block_text_schema(x, y, width, value_h, value_font, font_size, value, color, alignment, line_height)
                y += value_h + entry_gap
            else
                value_h = estimate_text_height_mm(value, font_size, line_height, width)
                break if y + value_h > max_y + 0.5
                out << make_block_text_schema(x, y, width, value_h, value_font, font_size, value, color, alignment, line_height)
                y += value_h + entry_gap
            end
        end
        out
    end

    # Filter the raw comment list down to what this block should render (approved + optionally
    # pending). Comments with no text after stripping are dropped — those can never produce
    # visible output on the page.
    def visible_comments_for_block(comments, include_pending)
        comments.select do |c|
            status = (c['status'] || 'pending').to_s
            (status == 'approved' || (include_pending && status == 'pending')) && !c['text'].to_s.strip.empty?
        end
    end

    # Render as many comments as fit, starting from `start_idx` in the already-filtered list.
    # Returns [emitted_schemas, end_idx] so the caller can decide whether to paginate.
    def render_comments_block(block, config, visible_comments, start_idx = 0)
        out = []
        pos = block['position'] || { 'x' => 0, 'y' => 0 }
        x = pos['x'].to_f
        y_start = pos['y'].to_f
        max_y = y_start + block['height'].to_f
        width = block['width'].to_f

        font_size = (config['font_size'] || block['fontSize'] || 10).to_f
        line_height = (config['line_height'] || 1.4).to_f
        entry_gap = (config['entry_gap_mm'] || 2).to_f
        text_font = config['font_name'] || block['fontName']
        author_font = config['author_font_name'] || text_font
        color = block['fontColor'] || '#000000'
        alignment = block['alignment'] || 'left'
        show_author = config['show_author'] != false

        idx = start_idx
        y = y_start
        while idx < visible_comments.length
            c = visible_comments[idx]
            text = c['text'].to_s.strip
            author = c['commenter_name'].to_s.strip
            author_line = author.empty? ? '' : "— #{author}"

            text_h = estimate_text_height_mm(text, font_size, line_height, width)
            author_h = (show_author && !author_line.empty?) ? estimate_text_height_mm(author_line, font_size, line_height, width) : 0.0

            # If this comment doesn't fit and we've already emitted at least one, stop —
            # the caller will paginate. If we've emitted nothing and this single comment
            # is larger than the block, force-render it anyway so we never deadlock.
            if y + text_h + author_h > max_y + 0.5
                break if idx > start_idx
            end

            out << make_block_text_schema(x, y, width, text_h, text_font, font_size, text, color, alignment, line_height)
            y += text_h
            if show_author && !author_line.empty?
                out << make_block_text_schema(x, y, width, author_h, author_font, font_size, author_line, color, alignment, line_height)
                y += author_h
            end
            y += entry_gap
            idx += 1
        end
        [out, idx]
    end

    # Expand block placeholders on a single page. Returns [new_page_schemas, end_idx]
    # where end_idx is the next index into visible_comments after this page consumed its
    # share — the page builder uses that to paginate the comments-overflow page.
    def expand_page_blocks(page_schemas, blocks_config, profile, answers, visible_comments, comments_start_idx)
        return [page_schemas, comments_start_idx] unless blocks_config.is_a?(Hash) && !blocks_config.empty?

        new_page = []
        end_idx = comments_start_idx
        (page_schemas || []).each do |entry|
            cfg = entry.is_a?(Hash) ? blocks_config[entry['name']] : nil
            if cfg.is_a?(Hash)
                case cfg['kind']
                when 'fields'
                    new_page.concat(render_fields_block(entry, cfg, profile, answers))
                when 'comments'
                    emitted, next_idx = render_comments_block(entry, cfg, visible_comments, end_idx)
                    new_page.concat(emitted)
                    end_idx = next_idx
                end
            else
                new_page << entry
            end
        end
        [new_page, end_idx]
    end

    # Are there any comments-kind blocks on this page? If not, the page builder doesn't
    # need to spin the "duplicate the page to fit overflow" loop.
    def page_has_comments_block?(page_schemas, blocks_config)
        return false unless blocks_config.is_a?(Hash) && !blocks_config.empty?
        (page_schemas || []).any? do |e|
            e.is_a?(Hash) && blocks_config[e['name']].is_a?(Hash) &&
                blocks_config[e['name']]['kind'] == 'comments'
        end
    end

    # Look up the latest upload (if any) for a given context+field_id and return a data URL,
    # or nil if no usable file exists.
    def yearbook_upload_data_url(username, context, field_id)
        results = neo4j_query(<<~END_OF_QUERY, {username: username, context: context, field_id: field_id})
            MATCH (u:User {username: $username})-[:HAS_YEARBOOK_UPLOAD]->(up:YearbookUpload {context: $context, field_id: $field_id})
            RETURN up.id AS id, up.original_filename AS filename, up.mimetype AS mimetype
            ORDER BY up.created_at DESC
            LIMIT 1
        END_OF_QUERY
        return nil if results.empty?

        upload = results.first
        path = File.join(YEARBOOK_UPLOAD_PATH, "#{upload['id']}_#{upload['filename']}")
        return nil unless File.exist?(path)

        mime = upload['mimetype'].to_s
        mime = 'image/jpeg' if mime.empty?
        return nil unless mime.start_with?('image/')

        "data:#{mime};base64,#{Base64.strict_encode64(File.binread(path))}"
    end

    # Build pdfme `inputs` for one user, given the schema currently saved.
    # Only fields actually placed on the page are filled in.
    def build_yearbook_inputs_for_user(username, template)
        catalog = yearbook_template_field_catalog.each_with_object({}) { |f, h| h[f['name']] = f }

        # Schueler / display name
        user_info = neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})
            OPTIONAL MATCH (u)-[:IS_SCHUELER]->(s:Schueler)
            RETURN u.username AS username, COALESCE(s.name, u.name) AS display_name,
                   s.id AS schueler_id
        END_OF_QUERY
        return nil if user_info.empty?
        display_name = user_info.first['display_name'].to_s
        schueler_id = user_info.first['schueler_id']

        # Profile fields
        profile = get_yearbook_profile_data(username) || {}

        # Answers
        entries = neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})-[:HAS_YEARBOOK_ENTRY]->(y:YearbookEntry)
            RETURN y.question_id AS question_id, y.answer AS answer
        END_OF_QUERY
        answers = {}
        entries.each { |e| answers[e['question_id']] = e['answer'] }

        # Approved comments (joined)
        comments_text = ''
        if schueler_id
            comment_rows = neo4j_query(<<~END_OF_QUERY, {schueler_id: schueler_id})
                MATCH (:User)-[:WROTE_YEARBOOK_COMMENT]->(c:YearbookComment)-[:ON_YEARBOOK_ENTRY_OF]->(s:Schueler {id: $schueler_id})
                WHERE COALESCE(c.status, 'pending') = 'approved'
                RETURN c.text AS text
                ORDER BY c.created_at
            END_OF_QUERY
            comments_text = comment_rows.map { |r| r['text'].to_s.strip }.reject(&:empty?).join(' — ')
        end

        # Iterate schema pages and collect field names that are actually placed.
        used_names = []
        (template['schemas'] || []).each do |page|
            next unless page.is_a?(Array)
            page.each do |entry|
                used_names << entry['name'] if entry.is_a?(Hash) && entry['name'].is_a?(String)
            end
        end
        used_names.uniq!

        inputs_page = {}
        used_names.each do |name|
            cat = catalog[name]
            if cat.nil?
                # Unknown field (asset, accent rectangle, or arbitrary admin-added element).
                # These are forced to readOnly upstream so pdfme uses schema.content; we must
                # NOT add an inputs entry (an empty string here would still leak through if
                # someone removes the readOnly flag).
                next
            end

            case cat['type']
            when 'image'
                data_url = case cat['source']
                           when 'profile' then yearbook_upload_data_url(username, 'profile', cat['field_id'])
                           when 'answer'  then yearbook_upload_data_url(username, 'answer',  cat['field_id'])
                           else nil
                           end
                inputs_page[name] = data_url.to_s # empty string -> pdfme renders nothing
            else
                value = case cat['source']
                        when 'meta'
                            case cat['field_id']
                            when 'display_name' then display_name
                            when 'comments' then comments_text
                            when YEARBOOK_BIO_BLOCK_NAME then build_bio_block_text(profile, answers)
                            else ''
                            end
                        when 'profile'
                            profile[cat['field_id']].to_s
                        when 'answer'
                            raw = answers[cat['field_id']].to_s
                            # multiple_choice answers are JSON arrays; flatten them.
                            begin
                                parsed = JSON.parse(raw)
                                raw = parsed.join(', ') if parsed.is_a?(Array)
                            rescue
                            end
                            raw
                        else
                            ''
                        end
                inputs_page[name] = value
            end
        end

        # pdfme inputs is an array of input objects, one per output document.
        [inputs_page]
    end

    # Call the Node.js pdfme generator with one or more {template, inputs} jobs.
    # Each job is generated independently and the resulting PDFs are concatenated
    # by the Node script (via pdf-lib). Returns the PDF binary, or raises.
    def render_yearbook_pdf_jobs(jobs)
        payload = JSON.dump({
            'jobs'  => jobs,
            'fonts' => yearbook_fonts_payload
        })
        env = { 'NODE_PATH' => YEARBOOK_PDFME_NODE_MODULES }
        stdout, stderr, status = Open3.capture3(
            env, 'node', YEARBOOK_PDFME_SCRIPT,
            stdin_data: payload, binmode: true
        )
        unless status.success?
            debug_error "pdfme generation failed: #{stderr}"
            assert(false, "PDF-Generierung fehlgeschlagen: #{stderr.to_s.lines.last.to_s.strip}")
        end
        stdout.force_encoding('ASCII-8BIT')
    end

    # pdfme's generator (generate.js) resolves the value of a schema like:
    #   value = schema.readOnly ? schema.content : (input[name] || '')
    # So any schema we don't want overridden by inputs — assets, accent rectangles, or
    # text/images the admin placed manually with arbitrary names — must be marked as
    # readOnly so its design-time `content` survives. Otherwise pdfme renders the
    # fallback empty string, which for images means "no image at all".
    def force_static_schemas_readonly!(template, catalog_names)
        (template['schemas'] || []).each do |page|
            next unless page.is_a?(Array)
            page.each do |entry|
                next unless entry.is_a?(Hash)
                name = entry['name']
                next unless name.is_a?(String)
                entry['readOnly'] = true unless catalog_names.include?(name)
            end
        end
        template
    end

    # Build a single render job for one user: pick variant, apply accent colour,
    # build inputs. Returns nil if the user doesn't exist.
    # If the variant references a background PDF that exists on disk, replace the
    # template's basePdf with that PDF's bytes as a base64 data URL. pdfme then renders
    # all schemas on top of the existing PDF page instead of a blank A4.
    def apply_background_pdf_to_template!(template, background_filename)
        return template if background_filename.to_s.empty?
        return template unless yearbook_background_files.include?(background_filename)
        path = File.join(YEARBOOK_BACKGROUNDS_DIR, background_filename)
        return template unless File.exist?(path)
        template['basePdf'] = "data:application/pdf;base64,#{Base64.strict_encode64(File.binread(path))}"
        template
    end

    # Build one or more pdfme jobs for a user. Returns an array of {template, inputs}.
    #
    # Page 0 = Steckbrief, rendered exactly once.
    # Pages 1..N-1 = additional pages (typically comment pages). The LAST page acts as
    # the comments-overflow template: it is duplicated as many times as needed to fit
    # all of the student's comments. If the student has no comments but the last page
    # has a comments block, the page is still rendered once (so every student gets at
    # least one comment page).
    def build_yearbook_jobs_for_user(username, variant_set)
        # A personalised template (if the student customised their page) takes precedence
        # over the global variant selection.
        if yearbook_user_customization_enabled?
            personal = load_user_yearbook_template(username)
            return build_personal_yearbook_jobs(username, personal) if personal
        end

        variant = pick_yearbook_variant_for_user(username, variant_set)
        return [] unless variant

        # Load the per-user data once and reuse it across all expansion stages.
        user_info = neo4j_query(<<~END_OF_QUERY, {username: username}).first
            MATCH (u:User {username: $username})
            RETURN u.username AS username
        END_OF_QUERY
        return [] unless user_info
        profile = get_yearbook_profile_data(username) || {}
        answer_rows = neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})-[:HAS_YEARBOOK_ENTRY]->(y:YearbookEntry)
            RETURN y.question_id AS question_id, y.answer AS answer
        END_OF_QUERY
        answers = answer_rows.each_with_object({}) { |r, h| h[r['question_id']] = r['answer'] }
        comments = yearbook_comments_for_user(username)

        accent = yearbook_accent_color_for_user(username)
        base_template = apply_accent_color_to_template(variant['template'], accent, variant['accent_placeholder_hex'])
        recolor_marked_images!(base_template, variant['recolor_images'], variant['accent_placeholder_hex'], accent)
        apply_background_pdf_to_template!(base_template, variant['background_pdf'])

        blocks_config = variant['yearbook_blocks'] || {}
        catalog_names = yearbook_template_field_catalog.map { |f| f['name'] }

        pages = base_template['schemas'] || []
        return [] if pages.empty?

        jobs = []
        comments_idx = 0

        # Pre-filter comments for any include_pending settings in use. Different comments
        # blocks could in principle use different filters; in practice they don't, so we
        # take the most permissive view (include_pending=true if any block enables it).
        any_include_pending = blocks_config.values.any? { |c| c.is_a?(Hash) && c['kind'] == 'comments' && c['include_pending'] }
        visible_comments = visible_comments_for_block(comments, any_include_pending)

        last_idx = pages.length - 1
        pages.each_with_index do |page_schemas, page_idx|
            is_last = (page_idx == last_idx)
            iterations = 0
            loop do
                iterations += 1
                expanded_page, next_comments_idx = expand_page_blocks(
                    page_schemas, blocks_config, profile, answers, visible_comments, comments_idx
                )
                page_template = base_template.dup
                page_template['schemas'] = [expanded_page]
                force_static_schemas_readonly!(page_template, catalog_names)
                inputs = build_yearbook_inputs_for_user(username, page_template)
                jobs << { 'template' => page_template, 'inputs' => inputs } if inputs

                comments_idx = next_comments_idx if next_comments_idx > comments_idx

                if is_last && page_has_comments_block?(page_schemas, blocks_config)
                    # Spill the last page as many times as needed to consume remaining comments.
                    break if comments_idx >= visible_comments.length
                    # Safety brake: if a single iteration made no progress AND we've looped
                    # several times, bail out so we don't hang the request.
                    break if iterations > 50
                else
                    break
                end
            end
        end

        jobs
    end

    # ----- routes ----------------------------------------------------------

    # JSON: list of available fields, fonts and image assets for the designer sidebar.
    # Fonts and assets are served as plain static files via nginx; we just hand the
    # designer a discovery list. URLs are relative to the site root.
    post '/api/yearbook/template/fields' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        fonts = yearbook_font_files.map do |filename|
            { 'name' => yearbook_font_name_for(filename),
              'filename' => filename,
              'url' => "/include/yearbook_fonts/#{filename}" }
        end
        assets = yearbook_asset_files.map do |filename|
            { 'filename' => filename,
              'url' => "/include/yearbook_assets/#{filename}" }
        end

        backgrounds = yearbook_background_files.map do |filename|
            { 'filename' => filename,
              'url' => "/include/yearbook_backgrounds/#{filename}" }
        end

        respond(success: true,
                fields: yearbook_template_field_catalog,
                block_fields: yearbook_block_field_options,
                fonts: fonts,
                assets: assets,
                backgrounds: backgrounds)
    end

    # JSON: load full variant set.
    post '/api/yearbook/template/get' do
        require_user!
        require_user_with_permission!("yearbook_manage")
        respond(success: true, variant_set: load_yearbook_variant_set)
    end

    # JSON: save full variant set. Body: { variant_set: { variants: [...] } }
    post '/api/yearbook/template/save' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        # Variants with inlined image assets (data URLs) can grow several MB each,
        # and admins may have several variants.
        data = parse_request_data(
            required_keys: [:variant_set],
            max_body_length: 50_000_000,
            max_string_length: 50_000_000
        )

        vs = data[:variant_set]
        assert(vs.is_a?(Hash), "Ungültiges Variantenset")
        assert(vs['variants'].is_a?(Array) && !vs['variants'].empty?, "Mindestens eine Variante erforderlich")
        sanitized = {
            'version' => 2,
            'variants' => vs['variants'].map { |v| sanitize_yearbook_variant(v) }
        }

        FileUtils.mkdir_p(File.dirname(YEARBOOK_TEMPLATE_PATH))
        File.write(YEARBOOK_TEMPLATE_PATH, JSON.pretty_generate(sanitized))

        log("Jahrbuch-Variantenset gespeichert (#{sanitized['variants'].size} Varianten) durch #{@session_user[:username]}")
        respond(success: true, message: "Varianten gespeichert", variant_count: sanitized['variants'].size)
    end

    # Per-user variant pinning and accent colour overview (yearbook_manage only).
    post '/api/yearbook/template/assignments' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        rows = neo4j_query(<<~END_OF_QUERY)
            MATCH (u:User)
            WHERE (u)-[:HAS_YEARBOOK_PROFILE]->() OR (u)-[:HAS_YEARBOOK_ENTRY]->()
            OPTIONAL MATCH (u)-[:IS_SCHUELER]->(s:Schueler)
            OPTIONAL MATCH (u)-[:HAS_YEARBOOK_UPLOAD]->(up:YearbookUpload) WHERE up.mimetype STARTS WITH 'image/'
            WITH u, s, count(up) AS photo_count
            RETURN u.username AS username,
                   COALESCE(s.name, u.name) AS display_name,
                   photo_count,
                   u.yearbook_template_variant AS variant_id,
                   u.yearbook_accent_color AS accent_color
            ORDER BY display_name
        END_OF_QUERY
        customization_enabled = yearbook_user_customization_enabled?
        users = rows.map { |r| {
            username: r['username'],
            display_name: r['display_name'],
            photo_count: r['photo_count'].to_i,
            variant_id: r['variant_id'],
            accent_color: r['accent_color'] || YEARBOOK_DEFAULT_ACCENT_COLOR,
            has_custom: customization_enabled && File.exist?(user_yearbook_template_path(r['username']))
        } }

        variant_set = load_yearbook_variant_set
        variants = (variant_set['variants'] || []).map { |v| {
            id: v['id'], name: v['name'], photo_count: v['photo_count']
        } }

        respond(success: true, users: users, variants: variants,
                customization_enabled: customization_enabled,
                default_accent_color: YEARBOOK_DEFAULT_ACCENT_COLOR)
    end

    # Pin a variant for a user (or clear by passing variant_id: ""). yearbook_manage only.
    post '/api/yearbook/template/set_user_variant' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        data = parse_request_data(required_keys: [:username, :variant_id])
        username = data[:username].to_s.strip
        variant_id = data[:variant_id].to_s.strip
        assert(username =~ YEARBOOK_USERNAME_FORMAT, "Ungültiger Benutzername")

        if variant_id.empty?
            neo4j_query(<<~END_OF_QUERY, {username: username})
                MATCH (u:User {username: $username}) REMOVE u.yearbook_template_variant
            END_OF_QUERY
        else
            assert(variant_id =~ /\A[A-Za-z0-9_-]+\z/, "Ungültige Varianten-ID")
            neo4j_query(<<~END_OF_QUERY, {username: username, vid: variant_id})
                MATCH (u:User {username: $username}) SET u.yearbook_template_variant = $vid
            END_OF_QUERY
        end
        respond(success: true)
    end

    # Bulk accent-colour fetch for the jahrbuch_manage overview.
    # Visible to yearbook_view; editing still requires yearbook_create (own) or _manage (other).
    post '/api/yearbook/template/accent_colors' do
        require_user!
        assert(user_has_permission?("yearbook_view") || user_has_permission?("yearbook_manage"),
               "Keine Berechtigung")

        rows = neo4j_query(<<~END_OF_QUERY)
            MATCH (u:User)
            WHERE (u)-[:HAS_YEARBOOK_PROFILE]->() OR (u)-[:HAS_YEARBOOK_ENTRY]->()
            RETURN u.username AS username, u.yearbook_accent_color AS color
        END_OF_QUERY
        map = {}
        rows.each do |r|
            c = r['color']
            map[r['username']] = (c.is_a?(String) && c =~ /\A#[0-9A-Fa-f]{6}\z/) ? c : YEARBOOK_DEFAULT_ACCENT_COLOR
        end
        respond(success: true, colors: map, default_color: YEARBOOK_DEFAULT_ACCENT_COLOR)
    end

    # Get accent colour. Self is always allowed; yearbook_manage may target anyone.
    post '/api/yearbook/accent_color/get' do
        require_user!
        require_yearbook_accessible!
        data = parse_request_data(optional_keys: [:target_username])
        username = resolve_target_username(data[:target_username])
        respond(success: true, color: yearbook_accent_color_for_user(username),
                default_color: YEARBOOK_DEFAULT_ACCENT_COLOR)
    end

    # Set accent colour. yearbook_manage only — students do not pick their own colour
    # (the accent is a design decision, owned by the yearbook team).
    post '/api/yearbook/accent_color/set' do
        require_user!
        require_yearbook_accessible!
        require_user_with_permission!("yearbook_manage")

        data = parse_request_data(required_keys: [:color, :target_username])
        color = data[:color].to_s.strip
        assert(color =~ /\A#[0-9A-Fa-f]{6}\z/, "Ungültiger Farbwert (#RRGGBB erwartet)")
        target = data[:target_username].to_s.strip
        assert(target =~ YEARBOOK_USERNAME_FORMAT, "Ungültiger Benutzername")

        neo4j_query(<<~END_OF_QUERY, {username: target, color: color})
            MATCH (u:User {username: $username}) SET u.yearbook_accent_color = $color
        END_OF_QUERY
        respond(success: true, color: color)
    end

    # PDF preview for a single user (uses the variant best matching the user's photo count
    # plus any admin pin, and substitutes the user's accent colour).
    get '/api/yearbook/preview/:username' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        username = params[:username].to_s.strip
        assert(username =~ YEARBOOK_USERNAME_FORMAT, "Ungültiger Benutzername")

        variant_set = load_yearbook_variant_set
        jobs = build_yearbook_jobs_for_user(username, variant_set)
        assert(!jobs.empty?, "Benutzer nicht gefunden oder keine Vorlage verfügbar")

        pdf_bytes = render_yearbook_pdf_jobs(jobs)

        # respond_raw_with_mimetype sets @respond_content / @respond_mimetype so the after-hook
        # writes the PDF body verbatim. We add an explicit inline Content-Disposition so the
        # browser previews the file rather than offering it as a download (the hook only sets
        # Content-Disposition when @respond_filename is non-nil, which it isn't here).
        respond_raw_with_mimetype(pdf_bytes, 'application/pdf')
        response.headers['Content-Disposition'] = "inline; filename=\"jahrbuch_#{username}.pdf\""
    end

    # Bulk PDF export: every student rendered with their individually picked variant and
    # accent colour. The Node script concatenates the per-user PDFs via pdf-lib.
    get '/api/yearbook/export_pdf' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        variant_set = load_yearbook_variant_set

        targets = neo4j_query(<<~END_OF_QUERY)
            MATCH (u:User)
            WHERE (u)-[:HAS_YEARBOOK_PROFILE]->() OR (u)-[:HAS_YEARBOOK_ENTRY]->()
            OPTIONAL MATCH (u)-[:IS_SCHUELER]->(s:Schueler)
            RETURN u.username AS username, COALESCE(s.name, u.name) AS display_name
            ORDER BY display_name
        END_OF_QUERY

        jobs = []
        targets.each do |row|
            jobs.concat(build_yearbook_jobs_for_user(row['username'], variant_set))
        end

        # Always send at least one job so the Node script doesn't fail; a blank A4
        # template with no inputs renders as an empty page.
        if jobs.empty?
            fallback = variant_set['variants'].first
            jobs << { 'template' => fallback['template'], 'inputs' => [{}] }
        end

        pdf_bytes = render_yearbook_pdf_jobs(jobs)

        respond_raw_with_mimetype_and_filename(
            pdf_bytes,
            'application/pdf',
            "jahrbuch_#{Date.today}.pdf"
        )
    end

    # List of users that have at least a YearbookProfile or YearbookEntry,
    # used by the designer to pick a preview target.
    post '/api/yearbook/template/preview_targets' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        results = neo4j_query(<<~END_OF_QUERY)
            MATCH (u:User)
            WHERE (u)-[:HAS_YEARBOOK_PROFILE]->() OR (u)-[:HAS_YEARBOOK_ENTRY]->()
            OPTIONAL MATCH (u)-[:IS_SCHUELER]->(s:Schueler)
            RETURN u.username AS username, COALESCE(s.name, u.name) AS display_name
            ORDER BY display_name
        END_OF_QUERY
        users = results.map { |r| { username: r['username'], display_name: r['display_name'] } }
        respond(success: true, users: users)
    end

    # ----- personalised (per-user) template routes -------------------------

    # Load the user's personalised template (or a freshly baked seed from their variant if
    # they haven't customised yet), plus everything the designer sidebar needs. With
    # yearbook_manage, a target_username may be supplied to edit someone else's page.
    post '/api/yearbook/my_template/get' do
        require_user!
        require_yearbook_accessible!
        assert(yearbook_user_customization_enabled?, "Individualisierung ist deaktiviert")

        data = parse_request_data(optional_keys: [:target_username])
        username = authorize_personalize_target!(data[:target_username])

        variant_set = load_yearbook_variant_set
        personal = load_user_yearbook_template(username)
        is_custom = !personal.nil?

        if personal
            template = personal['template']
            background_pdf = personal['background_pdf']
            refresh_catalog_content!(template, username)
        else
            seed = build_baked_personal_seed(username, variant_set)
            assert(seed, "Keine Vorlage verfügbar")
            template = seed['template']
            background_pdf = seed['background_pdf']
        end

        fonts = yearbook_font_files.map do |filename|
            { 'name' => yearbook_font_name_for(filename),
              'filename' => filename,
              'url' => "/include/yearbook_fonts/#{filename}" }
        end
        assets = yearbook_asset_files.map do |filename|
            { 'filename' => filename, 'url' => "/include/yearbook_assets/#{filename}" }
        end
        backgrounds = yearbook_background_files.map do |filename|
            { 'filename' => filename, 'url' => "/include/yearbook_backgrounds/#{filename}" }
        end

        respond(
            success: true,
            template: template,
            background_pdf: background_pdf,
            is_custom: is_custom,
            fields: yearbook_template_field_values_for_user(username),
            assets: assets,
            backgrounds: backgrounds,
            fonts: fonts
        )
    end

    # Save the user's personalised template.
    post '/api/yearbook/my_template/save' do
        require_user!
        require_yearbook_accessible!
        assert(yearbook_user_customization_enabled?, "Individualisierung ist deaktiviert")

        data = parse_request_data(
            required_keys: [:template],
            optional_keys: [:target_username, :background_pdf],
            max_body_length: 50_000_000,
            max_string_length: 50_000_000
        )
        username = authorize_personalize_target!(data[:target_username])

        save_user_yearbook_template(username, data[:template], data[:background_pdf])

        log("Persönliche Jahrbuch-Vorlage für #{username} gespeichert durch #{@session_user[:username]}")
        respond(success: true, message: "Deine Jahrbuchseite wurde gespeichert.")
    end

    # Discard the user's personalisation and fall back to the global variant.
    post '/api/yearbook/my_template/reset' do
        require_user!
        require_yearbook_accessible!
        assert(yearbook_user_customization_enabled?, "Individualisierung ist deaktiviert")

        data = parse_request_data(optional_keys: [:target_username])
        username = authorize_personalize_target!(data[:target_username])

        delete_user_yearbook_template(username)

        log("Persönliche Jahrbuch-Vorlage für #{username} zurückgesetzt durch #{@session_user[:username]}")
        respond(success: true, message: "Auf das Standard-Design zurückgesetzt.")
    end

    # Inline PDF preview of the requesting user's own page (uses their personalisation if
    # present). For previewing another user's page, yearbook_manage uses
    # /api/yearbook/preview/:username.
    get '/api/yearbook/my_template/preview' do
        require_user_with_permission!("yearbook_create")
        require_yearbook_accessible!
        assert(yearbook_user_customization_enabled?, "Individualisierung ist deaktiviert")

        username = @session_user[:username]
        variant_set = load_yearbook_variant_set
        jobs = build_yearbook_jobs_for_user(username, variant_set)
        assert(!jobs.empty?, "Keine Vorlage verfügbar")

        pdf_bytes = render_yearbook_pdf_jobs(jobs)
        respond_raw_with_mimetype(pdf_bytes, 'application/pdf')
        response.headers['Content-Disposition'] = "inline; filename=\"jahrbuch_meine_seite.pdf\""
    end
end
