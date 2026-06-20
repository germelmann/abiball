require 'base64'
require 'chunky_png'
require 'digest'
require 'fileutils'
require 'json'
require 'time'
require 'open3'
require 'zlib'

class Main < Sinatra::Base

    YEARBOOK_TEMPLATE_PATH = '/raw/yearbook_template.json'
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

    # Emoji font, shipped to the PDF generator so emoji in comments/profile fields render
    # as monochrome glyphs. We deliberately do NOT use the system NotoColorEmoji.ttf:
    # that is a CBDT/CBLC colour *bitmap* font with no `glyf` outlines, and pdf-lib/fontkit
    # cannot embed bitmap-colour fonts — emoji silently rendered as nothing. The committed
    # NotoColorEmoji-Regular.ttf carries `glyf` outlines, which pdf-lib embeds and renders
    # as monochrome emoji glyphs. It lives outside YEARBOOK_FONTS_DIR on purpose so it never
    # shows up as a selectable body font in the designer's font picker.
    #
    # pdfme renders exactly one font per text field and has no per-glyph fallback, so simply
    # registering this font does NOT make emoji appear inside admin-font text. generate_pdf.js
    # replaces pdfme's text plugin with a renderer that splits each line into runs and draws
    # emoji graphemes with this font while keeping body text in the admin font.
    YEARBOOK_EMOJI_FONT_PATH = '/src/static/include/fonts/NotoColorEmoji-Regular.ttf'
    YEARBOOK_EMOJI_FONT_NAME = 'NotoColorEmoji'

    # Build { fontName => base64-of-binary } for shipping to Node. The first font (sorted)
    # is the fallback — pdfme requires exactly one font with fallback=true. If no admin
    # fonts are present we return an empty hash; the Node script then leaves
    # options.font undefined and pdfme falls back to its bundled Roboto.
    # NotoColorEmoji is always appended (as an ordinary, non-fallback font) so the Node
    # script's per-glyph renderer can draw emoji with it.
    def yearbook_fonts_payload
        files = yearbook_font_files
        # When no admin fonts are configured, return an empty hash so the Node script
        # leaves options.font undefined and pdfme falls back to its bundled Roboto — which
        # correctly covers Latin/German text.  We only inject NotoColorEmoji when at least
        # one admin font is present; emoji then render via the Node script's per-glyph
        # fallback renderer while Latin glyphs come from the explicitly-named admin font.
        return {} if files.empty?
        h = files.each_with_object({}) do |filename, acc|
            name = yearbook_font_name_for(filename)
            path = File.join(YEARBOOK_FONTS_DIR, filename)
            next unless File.file?(path)
            acc[name] = {
                'data' => Base64.strict_encode64(File.binread(path)),
                'fallback' => acc.empty?
            }
        end
        # Append the emoji font as an ordinary font (fallback:false). generate_pdf.js draws
        # emoji graphemes with it per-glyph; it must NOT become pdfme's fallback font (that is
        # only the default for fields without a fontName, which would render such fields all in
        # emoji glyphs). Latin/German text stays covered by the explicitly-named admin fonts.
        if File.file?(YEARBOOK_EMOJI_FONT_PATH)
            h[YEARBOOK_EMOJI_FONT_NAME] = {
                'data' => Base64.strict_encode64(File.binread(YEARBOOK_EMOJI_FONT_PATH)),
                'fallback' => false
            }
        end
        h
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
        normalize_image_object_fit!(tpl)
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

    # ----- per-user manual override (hand-edited entry) -------------------
    #
    # A yearbook_manage user can open a student's completed entry in the editor,
    # tweak it (move an image, drop a line, …) and save the result as a manual
    # override. Once saved, the entry is rendered verbatim from this override,
    # independent of the variant design, and the student's own data is frozen
    # (see yearbook_user_locked? enforcement in yearbook.rb). The override can be
    # reset, which re-enables auto-generation from the variant design.
    #
    # The override template is stored on disk (it inlines images as data URLs and
    # can be several MB); a boolean flag on the User node mirrors its existence so
    # locking and overview queries don't have to touch the filesystem per user.
    YEARBOOK_OVERRIDE_DIR = '/raw/yearbook_overrides'

    # Filesystem-safe, collision-free path for a user's override (usernames may
    # contain @ . + - which we don't want in a filename).
    def yearbook_override_path(username)
        File.join(YEARBOOK_OVERRIDE_DIR, "#{Digest::SHA256.hexdigest(username.to_s)}.json")
    end

    def yearbook_user_has_override?(username)
        File.exist?(yearbook_override_path(username))
    end

    # True if the user's entry is locked for editing. Two independent mechanisms can
    # lock an entry, with the same effect on the student (data frozen, comment
    # moderation disabled):
    #   1. yearbook_manual_override — a manager hand-edited the entry's design and
    #      saved it as a per-user override (kept in sync with the override file).
    #   2. yearbook_finalized — a manager marked the entry as "done/abgeschlossen"
    #      without touching the design. The entry keeps rendering from the variant,
    #      and the flag can be toggled off again to re-open editing (see the
    #      /api/yearbook/finalize routes).
    def yearbook_user_locked?(username)
        r = neo4j_query(<<~END_OF_QUERY, {username: username}).first
            MATCH (u:User {username: $username})
            RETURN (COALESCE(u.yearbook_manual_override, false)
                    OR COALESCE(u.yearbook_finalized, false)) AS v
        END_OF_QUERY
        r ? (r['v'] == true) : false
    end

    # True if the entry was explicitly marked as finished/abgeschlossen (as opposed
    # to being locked via a manual design override).
    def yearbook_user_finalized?(username)
        r = neo4j_query(<<~END_OF_QUERY, {username: username}).first
            MATCH (u:User {username: $username})
            RETURN COALESCE(u.yearbook_finalized, false) AS v
        END_OF_QUERY
        r ? (r['v'] == true) : false
    end

    # Load the stored override template (the bare pdfme template hash), or nil.
    def load_yearbook_override(username)
        path = yearbook_override_path(username)
        return nil unless File.exist?(path)
        begin
            data = JSON.parse(File.read(path))
            tpl = data.is_a?(Hash) ? data['template'] : nil
            tpl.is_a?(Hash) ? tpl : nil
        rescue => e
            debug_error "Failed to read yearbook override for #{username}: #{e.message}"
            nil
        end
    end

    # Build a self-contained pdfme template for one user that the per-user editor
    # opens (when no override exists yet). Every dynamic element is resolved to a
    # concrete value baked into `content`, so the template renders with empty inputs.
    #
    # Crucially, field- and comments-blocks are collapsed into a SINGLE multi-line
    # text element each (not the per-line boxes the auto-layout uses). A single text
    # element lays out identically in the pdfme Designer (HTML) and in the generated
    # PDF (pdf-lib), so what the manager arranges in the editor matches the print —
    # the per-line estimate path (estimate_text_height_mm) only approximates the PDF
    # and drifts from the Designer's own line wrapping. Overrides are independent of
    # the variant design, so losing the auto-fit/per-author styling here is fine; the
    # manager has full manual control instead.
    def build_resolved_template_for_user(username, variant_set)
        variant = pick_yearbook_variant_for_user(username, variant_set)
        return nil unless variant

        user_info = neo4j_query(<<~END_OF_QUERY, {username: username}).first
            MATCH (u:User {username: $username}) RETURN u.username AS username
        END_OF_QUERY
        return nil unless user_info

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
        catalog = yearbook_template_field_catalog.each_with_object({}) { |f, h| h[f['name']] = f }
        # Resolve the concrete value (text or image data URL) of each catalog field
        # placed directly on the page; reuses the same logic the PDF render uses.
        inputs_page = (build_yearbook_inputs_for_user(username, base_template) || [{}])[0] || {}

        pages = base_template['schemas'] || []
        pages = cap_yearbook_pages(pages)

        resolved_pages = pages.map do |page|
            next [] unless page.is_a?(Array)
            page.map do |entry|
                next entry unless entry.is_a?(Hash)
                name = entry['name']
                cfg = name.is_a?(String) ? blocks_config[name] : nil
                if cfg.is_a?(Hash)
                    content = (cfg['kind'] == 'comments') ?
                        resolved_comments_block_text(cfg, comments) :
                        resolved_fields_block_text(cfg, profile, answers)
                    make_resolved_block_text_schema(entry, cfg, content)
                else
                    e = entry.dup
                    e['content'] = inputs_page[name].to_s if name.is_a?(String) && inputs_page.key?(name)
                    # Editable/movable in the designer; the render path forces readOnly
                    # again so the baked content is used verbatim.
                    e['readOnly'] = false
                    e
                end
            end
        end
        resolved_pages = [[]] if resolved_pages.empty?
        { 'basePdf' => base_template['basePdf'] || YEARBOOK_DEFAULT_BASE_PDF, 'schemas' => resolved_pages }
    end

    # Join all visible field-block values into one multi-line string. Mirrors
    # render_fields_block's content selection (labels, inline) but as plain lines.
    def resolved_fields_block_text(cfg, profile, answers)
        show_labels = cfg['show_labels'] != false
        inline = cfg['label_inline'] == true
        lines = []
        (cfg['fields'] || []).each do |fid|
            value = yearbook_block_field_value(fid, profile, answers)
            next if value.empty?
            label = yearbook_block_field_label(fid)
            if show_labels && inline
                lines << "#{label}: #{value}"
            elsif show_labels
                lines << "#{label}:"
                lines << value
            else
                lines << value
            end
        end
        lines.join("\n")
    end

    # Join all visible comments into one multi-line string (a blank line separates
    # consecutive comments, matching the visual gap of the auto-layout closely enough
    # while staying a single, WYSIWYG text element).
    def resolved_comments_block_text(cfg, comments)
        include_pending = cfg['include_pending'] == true
        show_author = cfg['show_author'] != false
        visible = visible_comments_for_block(comments, include_pending)
        lines = []
        visible.each do |c|
            text = c['text'].to_s.strip
            next if text.empty?
            lines << text
            author = c['commenter_name'].to_s.strip
            lines << "— #{author}" if show_author && !author.empty?
            lines << '' # blank separator line between comments
        end
        lines.pop while lines.last == '' && !lines.empty?
        lines.join("\n")
    end

    # Turn a block placeholder into a single concrete text schema carrying the joined
    # content, inheriting the block's configured font/size/colour/line-height so the
    # editor preview and the printed PDF use identical line spacing.
    def make_resolved_block_text_schema(placeholder, cfg, content)
        pos = placeholder['position'] || { 'x' => 0, 'y' => 0 }
        base_color = placeholder['fontColor'] || '#000000'
        if cfg['kind'] == 'comments'
            color = cfg['text_color'].to_s.empty? ? base_color : cfg['text_color'].to_s
            font  = cfg['font_name']
        else
            color = cfg['value_color'].to_s.empty? ? base_color : cfg['value_color'].to_s
            font  = cfg['value_font_name'] || cfg['font_name']
        end
        s = {
            'name' => placeholder['name'],
            'type' => 'text',
            'position' => { 'x' => pos['x'], 'y' => pos['y'] },
            'width' => placeholder['width'],
            'height' => placeholder['height'],
            'fontSize' => (cfg['font_size'] || placeholder['fontSize'] || 11).to_f,
            'fontColor' => color,
            'alignment' => placeholder['alignment'] || 'left',
            'lineHeight' => (cfg['line_height'] || 1.4).to_f,
            'content' => content.to_s,
            'readOnly' => false
        }
        s['fontName'] = font if font && !font.to_s.empty?
        s
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

    # The accent-colour palette managers (and optionally students) may pick from. Defined in
    # credentials as YEARBOOK_ACCENT_PALETTE; falls back to the default colour if unset/invalid.
    def yearbook_accent_palette
        pal = defined?(YEARBOOK_ACCENT_PALETTE) ? Array(YEARBOOK_ACCENT_PALETTE) : []
        pal = pal.select { |c| c.is_a?(String) && c =~ /\A#[0-9A-Fa-f]{6}\z/ }.uniq
        pal.empty? ? [YEARBOOK_DEFAULT_ACCENT_COLOR] : pal
    end

    # True if the given colour is part of the configured palette (case-insensitive).
    def yearbook_color_in_palette?(color)
        c = color.to_s
        yearbook_accent_palette.any? { |p| p.casecmp?(c) }
    end

    # Whether students may pick their own accent colour (from the palette) on their own page.
    # Defaults to disabled; admins enable it via the YEARBOOK_USER_COLOR_CHOICE_ENABLED credential.
    def yearbook_user_color_choice_enabled?
        defined?(YEARBOOK_USER_COLOR_CHOICE_ENABLED) && YEARBOOK_USER_COLOR_CHOICE_ENABLED
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

    # Ensure every image schema fills its box (cropping, not letterboxing). pdfme defaults
    # to "contain" when objectFit is missing, which leaves visible empty bars around images
    # that don't match the box aspect ratio — students expect the full frame to be filled.
    def normalize_image_object_fit!(template)
        return template unless template.is_a?(Hash) && template['schemas'].is_a?(Array)
        template['schemas'].each do |page|
            next unless page.is_a?(Array)
            page.each do |entry|
                next unless entry.is_a?(Hash) && entry['type'] == 'image'
                entry['objectFit'] = 'cover' unless entry['objectFit'].to_s == 'cover'
            end
        end
        template
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
    #       "font_name": "Roboto-Regular",   # comment text font
    #       "text_color": "#000000",          # comment text color (falls back to block fontColor)
    #       "text_bold": false,
    #       "author_font_name": "Roboto-Bold",
    #       "author_color": "#555555",        # author line color (falls back to text_color)
    #       "author_bold": false,
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

    # Estimate the rendered height of a text element in mm.
    # Uses word-boundary-aware wrapping to match pdfme's actual line-break behavior.
    # The 0.52× factor matches Roboto's actual average character width for mixed German
    # text more closely than the older 0.6 value, which over-estimated and caused
    # spurious blank lines between comments.  A 0.5mm tolerance in callers catches the
    # rare under-estimate for wide-character sequences.
    def estimate_text_height_mm(content, font_size_pt, line_height_factor, width_mm)
        return 0.0 if content.to_s.empty?
        line_h = font_size_pt * line_height_factor * PT_TO_MM
        avg_char_width_mm = font_size_pt * 0.52 * PT_TO_MM
        chars_per_line = [(width_mm.to_f / [avg_char_width_mm, 0.01].max).floor, 1].max
        total_lines = content.to_s.split("\n").sum do |row|
            next 1 if row.empty?
            # Simulate word-boundary wrapping: add words one-by-one onto lines.
            # This avoids under-counting when long words cause short words to strand
            # on the next line despite the aggregate character count fitting in fewer lines.
            words = row.split(/\s+/)
            line_count = 1
            line_chars = 0
            words.each do |word|
                wlen = word.length
                if line_chars == 0
                    line_chars = wlen
                elsif line_chars + 1 + wlen <= chars_per_line
                    line_chars += 1 + wlen
                else
                    line_count += 1
                    line_chars = wlen
                end
            end
            line_count
        end
        [line_h * total_lines, line_h].max
    end

    def estimate_text_width_mm(content, font_size_pt)
        content.to_s.length * font_size_pt * 0.52 * PT_TO_MM
    end

    def make_block_text_schema(x, y, width, height, font_name, font_size, content, color, alignment, line_height, bold: false)
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
        s['bold'] = true if bold
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
        label_color = config['label_color'].to_s.empty? ? color : config['label_color'].to_s
        value_color = config['value_color'].to_s.empty? ? color : config['value_color'].to_s
        label_bold = config['label_bold'] == true
        value_bold = config['value_bold'] == true
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
                    out << make_block_text_schema(x, y, width, label_h, label_font, font_size, label_with_colon, label_color, alignment, line_height, bold: label_bold)
                    y += label_h
                    out << make_block_text_schema(x, y, width, value_h, value_font, font_size, value, value_color, alignment, line_height, bold: value_bold)
                    y += value_h + entry_gap
                else
                    value_w = width - label_w
                    row_h = [estimate_text_height_mm(label_text, font_size, line_height, label_w),
                             estimate_text_height_mm(value, font_size, line_height, value_w)].max
                    break if y + row_h > max_y + 0.5
                    out << make_block_text_schema(x, y, label_w, row_h, label_font, font_size, label_text, label_color, alignment, line_height, bold: label_bold)
                    out << make_block_text_schema(x + label_w, y, value_w, row_h, value_font, font_size, value, value_color, alignment, line_height, bold: value_bold)
                    y += row_h + entry_gap
                end
            elsif show_labels
                # Label on its own line above the value. Label ends with a colon so the
                # visual relationship to its answer stays clear.
                label_with_colon = "#{label}:"
                label_h = estimate_text_height_mm(label_with_colon, font_size, line_height, width)
                value_h = estimate_text_height_mm(value, font_size, line_height, width)
                break if y + label_h + value_h > max_y + 0.5
                out << make_block_text_schema(x, y, width, label_h, label_font, font_size, label_with_colon, label_color, alignment, line_height, bold: label_bold)
                y += label_h
                out << make_block_text_schema(x, y, width, value_h, value_font, font_size, value, value_color, alignment, line_height, bold: value_bold)
                y += value_h + entry_gap
            else
                value_h = estimate_text_height_mm(value, font_size, line_height, width)
                break if y + value_h > max_y + 0.5
                out << make_block_text_schema(x, y, width, value_h, value_font, font_size, value, value_color, alignment, line_height, bold: value_bold)
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
    # Comment text and author name are emitted as separate schemas so each can carry its
    # own font name, color, and bold flag — mirroring the label/value split in render_fields_block.
    def render_comments_block(block, config, visible_comments, start_idx = 0)
        out = []
        pos = block['position'] || { 'x' => 0, 'y' => 0 }
        x = pos['x'].to_f
        y_start = pos['y'].to_f
        max_y = y_start + block['height'].to_f
        width = block['width'].to_f

        font_size = (config['font_size'] || block['fontSize'] || 10).to_f
        line_height = (config['line_height'] || 1.4).to_f
        line_h_mm = font_size * line_height * PT_TO_MM
        entry_gap = (config['entry_gap_mm'] || line_h_mm).to_f
        alignment = block['alignment'] || 'left'
        show_author = config['show_author'] != false

        # Comment text styling (analogous to "value" in a fields block)
        text_font = config['font_name'] || block['fontName']
        base_color = block['fontColor'] || '#000000'
        text_color = config['text_color'].to_s.empty? ? base_color : config['text_color'].to_s
        text_bold = config['text_bold'] == true

        # Author name styling (analogous to "label" in a fields block)
        author_font = config['author_font_name'] || text_font
        author_color = config['author_color'].to_s.empty? ? text_color : config['author_color'].to_s
        author_bold = config['author_bold'] == true

        idx = start_idx
        y = y_start
        while idx < visible_comments.length
            c = visible_comments[idx]
            text = c['text'].to_s.strip
            author = c['commenter_name'].to_s.strip
            author_str = (show_author && !author.empty?) ? "— #{author}" : nil

            text_h = estimate_text_height_mm(text, font_size, line_height, width)
            author_h = author_str ? estimate_text_height_mm(author_str, font_size, line_height, width) : 0.0
            total_h = text_h + author_h

            # If this comment doesn't fit and we've already emitted at least one, stop —
            # the caller will paginate. If we've emitted nothing and this single comment
            # is larger than the block, force-render it anyway so we never deadlock.
            if y + total_h > max_y + 0.5
                break if idx > start_idx
            end

            out << make_block_text_schema(x, y, width, text_h, text_font, font_size, text, text_color, alignment, line_height, bold: text_bold)
            y += text_h
            if author_str
                out << make_block_text_schema(x, y, width, author_h, author_font, font_size, author_str, author_color, alignment, line_height, bold: author_bold)
                y += author_h
            end
            y += entry_gap
            idx += 1
        end
        [out, idx]
    end

    # Like render_comments_block but tries progressively smaller font sizes until all
    # remaining comments (from start_idx to end) fit inside the block. This enforces the
    # two-page-per-person constraint: instead of duplicating the comments page, we shrink
    # the text so every comment fits in the one available page.
    # The font size is reduced in 0.5pt steps down to a minimum of YEARBOOK_COMMENTS_MIN_FONT_PT.
    YEARBOOK_COMMENTS_MIN_FONT_PT = 5.0

    def render_comments_block_autoscale(block, config, visible_comments, start_idx = 0)
        base_font = (config['font_size'] || block['fontSize'] || 10).to_f
        font = base_font
        while font >= YEARBOOK_COMMENTS_MIN_FONT_PT
            scaled_config = config.merge('font_size' => font.round(1))
            emitted, end_idx = render_comments_block(block, scaled_config, visible_comments, start_idx)
            return [emitted, end_idx] if end_idx >= visible_comments.length
            font -= 0.5
        end
        # At minimum font size accept whatever fits.
        render_comments_block(block, config.merge('font_size' => YEARBOOK_COMMENTS_MIN_FONT_PT), visible_comments, start_idx)
    end

    # Expand block placeholders on a single page. Returns [new_page_schemas, end_idx]
    # where end_idx is the next index into visible_comments after this page consumed its
    # share — the page builder uses that to paginate the comments-overflow page.
    # When fit_all_comments is true the comments block auto-scales to fit all remaining
    # comments rather than stopping at the block boundary.
    def expand_page_blocks(page_schemas, blocks_config, profile, answers, visible_comments, comments_start_idx, fit_all_comments: false)
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
                    if fit_all_comments
                        emitted, next_idx = render_comments_block_autoscale(entry, cfg, visible_comments, end_idx)
                    else
                        emitted, next_idx = render_comments_block(entry, cfg, visible_comments, end_idx)
                    end
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
        # DEBUG: record an entry marker so we can match Ruby-side context to the
        # Node script's debug log. Mirror script stderr (which includes the build
        # marker, per-image rendering decisions, etc.) into the same debug log
        # whether the generation succeeds or fails.
        debug_log_path = '/gen/log/yearbook_pdf_debug.log'
        begin
            FileUtils.mkdir_p(File.dirname(debug_log_path))
            File.open(debug_log_path, 'a') do |f|
                f.puts "[#{Time.now.utc.iso8601}] ruby: render_yearbook_pdf_jobs called, jobs=#{jobs.size}, script=#{YEARBOOK_PDFME_SCRIPT}, user=#{@session_user && @session_user[:username]}"
            end
        rescue
        end
        stdout, stderr, status = Open3.capture3(
            env, 'node', YEARBOOK_PDFME_SCRIPT,
            stdin_data: payload, binmode: true
        )
        begin
            File.open(debug_log_path, 'a') do |f|
                f.puts "[#{Time.now.utc.iso8601}] ruby: node exit=#{status.exitstatus} stdout=#{stdout.bytesize}B"
                unless stderr.to_s.empty?
                    f.puts "----- node stderr -----"
                    f.puts stderr
                    f.puts "----- end stderr -----"
                end
            end
        rescue
        end
        unless status.success?
            debug_error "pdfme generation failed: #{stderr}"
            assert(false, "PDF-Generierung fehlgeschlagen: #{stderr.to_s.lines.last.to_s.strip}")
        end
        stdout.force_encoding('ASCII-8BIT')
    end

    # Shared low-level Node invocation used by the file-based export helpers below.
    # Mirrors render_yearbook_pdf_jobs' logging but never holds the PDF bytes (the
    # Node script writes the output file itself when payload['out'] is set).
    def run_yearbook_pdf_node(payload, ctx)
        env = { 'NODE_PATH' => YEARBOOK_PDFME_NODE_MODULES }
        debug_log_path = '/gen/log/yearbook_pdf_debug.log'
        begin
            FileUtils.mkdir_p(File.dirname(debug_log_path))
            File.open(debug_log_path, 'a') { |f| f.puts "[#{Time.now.utc.iso8601}] ruby: pdf-node #{ctx}" }
        rescue
        end
        _stdout, stderr, status = Open3.capture3(
            env, 'node', YEARBOOK_PDFME_SCRIPT, stdin_data: payload, binmode: true
        )
        begin
            File.open(debug_log_path, 'a') do |f|
                f.puts "[#{Time.now.utc.iso8601}] ruby: node exit=#{status.exitstatus} (#{ctx})"
                unless stderr.to_s.empty?
                    f.puts "----- node stderr -----"; f.puts stderr; f.puts "----- end stderr -----"
                end
            end
        rescue
        end
        unless status.success?
            debug_error "pdfme node failed (#{ctx}): #{stderr}"
            assert(false, "PDF-Node fehlgeschlagen: #{stderr.to_s.lines.last.to_s.strip}")
        end
        status
    end

    # Render the given jobs and let Node write the resulting PDF directly to out_path,
    # so the (multi-MB) bytes never pass through this Ruby process. Pass a pre-computed
    # fonts payload to avoid re-encoding the fonts on every call. Used by the whole-
    # yearbook export worker to keep peak memory bounded to a single student.
    def render_yearbook_pdf_jobs_to_file(jobs, out_path, fonts_payload = nil)
        payload = JSON.dump({
            'jobs'  => jobs,
            'fonts' => fonts_payload || yearbook_fonts_payload,
            'out'   => out_path
        })
        run_yearbook_pdf_node(payload, "render #{jobs.size} job(s) -> #{out_path}")
        assert(File.exist?(out_path) && File.size(out_path) > 0, "PDF wurde nicht erzeugt: #{out_path}")
        out_path
    end

    # Stitch already-rendered PDF files (paths) into out_path via Node/pdf-lib.
    def merge_yearbook_pdf_files(paths, out_path)
        payload = JSON.dump({ 'mergeFiles' => paths, 'out' => out_path })
        run_yearbook_pdf_node(payload, "merge #{paths.size} file(s) -> #{out_path}")
        assert(File.exist?(out_path) && File.size(out_path) > 0, "Merge fehlgeschlagen: #{out_path}")
        out_path
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

    # Hard cap on the number of pages a single student's yearbook entry may occupy.
    YEARBOOK_MAX_PAGES_PER_USER = 2

    # Enforce the two-page-per-person layout (Steckbrief + one comments page). If a template
    # defines more pages, keep the first page (the Steckbrief) and the last page (the comments
    # page the builder auto-scales) and drop everything in between.
    def cap_yearbook_pages(pages)
        return pages if pages.length <= YEARBOOK_MAX_PAGES_PER_USER
        [pages.first, pages.last]
    end

    # Build one or more pdfme jobs for a user. Returns an array of {template, inputs}.
    #
    # Every student gets at most two pages (YEARBOOK_MAX_PAGES_PER_USER):
    # Page 0 = Steckbrief, rendered exactly once.
    # The LAST page = the comments page. It is NOT duplicated to fit overflow; instead the
    # comment font is auto-scaled so all of the student's comments fit on this single page.
    # Templates that define more than two pages are capped (see cap_yearbook_pages): the first
    # (Steckbrief) and last (comments) page are kept, the rest are dropped. If the student has
    # no comments but the last page has a comments block, the page is still rendered once.
    def build_yearbook_jobs_for_user(username, variant_set)
        # Manual override: a manager has hand-edited this user's page. Render it
        # verbatim, independent of the variant design. All schemas are forced
        # readOnly so their baked content is used (inputs are empty).
        override = load_yearbook_override(username)
        if override
            tpl = JSON.parse(JSON.dump(override))
            tpl['basePdf'] ||= YEARBOOK_DEFAULT_BASE_PDF
            force_static_schemas_readonly!(tpl, [])
            return [{ 'template' => tpl, 'inputs' => [{}] }]
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
        pages = cap_yearbook_pages(pages)

        jobs = []
        comments_idx = 0

        # Pre-filter comments for any include_pending settings in use. Different comments
        # blocks could in principle use different filters; in practice they don't, so we
        # take the most permissive view (include_pending=true if any block enables it).
        any_include_pending = blocks_config.values.any? { |c| c.is_a?(Hash) && c['kind'] == 'comments' && c['include_pending'] }
        visible_comments = visible_comments_for_block(comments, any_include_pending)

        # The last page acts as the comments page. Instead of duplicating it to fit
        # overflow, we auto-scale the comment font so all comments fit in exactly one
        # page — enforcing the two-page-per-person (Steckbrief + Kommentare) layout.
        last_idx = pages.length - 1
        pages.each_with_index do |page_schemas, page_idx|
            is_last = (page_idx == last_idx)
            fit_all = is_last && page_has_comments_block?(page_schemas, blocks_config)

            expanded_page, next_comments_idx = expand_page_blocks(
                page_schemas, blocks_config, profile, answers, visible_comments, comments_idx,
                fit_all_comments: fit_all
            )
            page_template = base_template.dup
            page_template['schemas'] = [expanded_page]
            force_static_schemas_readonly!(page_template, catalog_names)
            inputs = build_yearbook_inputs_for_user(username, page_template)
            jobs << { 'template' => page_template, 'inputs' => inputs } if inputs

            comments_idx = next_comments_idx if next_comments_idx > comments_idx
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
                   u.yearbook_accent_color AS accent_color,
                   COALESCE(u.yearbook_manual_override, false) AS manual_override,
                   COALESCE(u.yearbook_finalized, false) AS finalized
            ORDER BY display_name
        END_OF_QUERY
        users = rows.map { |r| {
            username: r['username'],
            display_name: r['display_name'],
            photo_count: r['photo_count'].to_i,
            variant_id: r['variant_id'],
            accent_color: r['accent_color'] || YEARBOOK_DEFAULT_ACCENT_COLOR,
            manual_override: r['manual_override'] == true,
            finalized: r['finalized'] == true
        } }

        variant_set = load_yearbook_variant_set
        variants = (variant_set['variants'] || []).map { |v| {
            id: v['id'], name: v['name'], photo_count: v['photo_count']
        } }

        respond(success: true, users: users, variants: variants,
                palette: yearbook_accent_palette,
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
        respond(success: true, colors: map, palette: yearbook_accent_palette,
                default_color: YEARBOOK_DEFAULT_ACCENT_COLOR)
    end

    # Get accent colour. Self is always allowed; yearbook_manage may target anyone.
    post '/api/yearbook/accent_color/get' do
        require_user!
        require_yearbook_accessible!
        data = parse_request_data(optional_keys: [:target_username])
        username = resolve_target_username(data[:target_username])
        respond(success: true, color: yearbook_accent_color_for_user(username),
                palette: yearbook_accent_palette,
                can_choose: yearbook_user_color_choice_enabled?,
                default_color: YEARBOOK_DEFAULT_ACCENT_COLOR)
    end

    # Set accent colour for a student. yearbook_manage only; the colour must be one of the
    # configured palette colours.
    post '/api/yearbook/accent_color/set' do
        require_user!
        require_yearbook_accessible!
        require_user_with_permission!("yearbook_manage")

        data = parse_request_data(required_keys: [:color, :target_username])
        color = data[:color].to_s.strip
        assert(yearbook_color_in_palette?(color), "Farbe ist nicht in der Palette")
        target = data[:target_username].to_s.strip
        assert(target =~ YEARBOOK_USERNAME_FORMAT, "Ungültiger Benutzername")

        neo4j_query(<<~END_OF_QUERY, {username: target, color: color})
            MATCH (u:User {username: $username}) SET u.yearbook_accent_color = $color
        END_OF_QUERY
        respond(success: true, color: color)
    end

    # Set one's OWN accent colour from the palette. Only available when students are allowed
    # to choose (YEARBOOK_USER_COLOR_CHOICE_ENABLED). Always targets the logged-in user.
    post '/api/yearbook/accent_color/set_own' do
        require_user!
        require_yearbook_accessible!
        assert(yearbook_user_color_choice_enabled?, "Farbwahl ist deaktiviert")

        data = parse_request_data(required_keys: [:color])
        color = data[:color].to_s.strip
        assert(yearbook_color_in_palette?(color), "Farbe ist nicht in der Palette")

        neo4j_query(<<~END_OF_QUERY, {username: @session_user[:username], color: color})
            MATCH (u:User {username: $username}) SET u.yearbook_accent_color = $color
        END_OF_QUERY
        respond(success: true, color: color)
    end

    # Assign a random palette colour to every yearbook user who has no valid colour yet.
    # yearbook_manage only. Returns the colours that were assigned.
    post '/api/yearbook/accent_color/randomize_unset' do
        require_user!
        require_yearbook_accessible!
        require_user_with_permission!("yearbook_manage")

        # When include_set is true, every yearbook user is re-randomised (overwriting colours
        # that were already chosen). Otherwise only users without a valid colour are touched.
        data = parse_request_data(optional_keys: [:include_set])
        include_set = [true, 'true', 1, '1'].include?(data[:include_set])

        palette = yearbook_accent_palette
        color_filter = include_set ? '' :
            "AND (u.yearbook_accent_color IS NULL OR NOT u.yearbook_accent_color =~ '#[0-9A-Fa-f]{6}')"
        rows = neo4j_query(<<~END_OF_QUERY)
            MATCH (u:User)
            WHERE ((u)-[:HAS_YEARBOOK_PROFILE]->() OR (u)-[:HAS_YEARBOOK_ENTRY]->())
              #{color_filter}
            RETURN u.username AS username
        END_OF_QUERY
        assigned = {}
        rows.each do |r|
            color = palette.sample
            neo4j_query(<<~END_OF_QUERY, {username: r['username'], color: color})
                MATCH (u:User {username: $username}) SET u.yearbook_accent_color = $color
            END_OF_QUERY
            assigned[r['username']] = color
        end
        respond(success: true, assigned: assigned, count: assigned.size)
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

    # ----- per-user manual override editor routes --------------------------

    # Load the template for the per-user entry editor. Returns the saved manual
    # override if one exists, otherwise a freshly-resolved template baked from the
    # user's data + assigned variant (so the editor always opens pre-filled).
    post '/api/yearbook/override/get' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        data = parse_request_data(required_keys: [:target_username])
        username = data[:target_username].to_s.strip
        assert(username =~ YEARBOOK_USERNAME_FORMAT, "Ungültiger Benutzername")

        user_info = neo4j_query(<<~END_OF_QUERY, {username: username}).first
            MATCH (u:User {username: $username})
            OPTIONAL MATCH (u)-[:IS_SCHUELER]->(s:Schueler)
            RETURN u.username AS username, COALESCE(s.name, u.name) AS display_name
        END_OF_QUERY
        assert(user_info, "Benutzer nicht gefunden")

        has_override = yearbook_user_has_override?(username)
        template = has_override ? load_yearbook_override(username) : nil
        if template.nil?
            variant_set = load_yearbook_variant_set
            template = build_resolved_template_for_user(username, variant_set)
            assert(template, "Für diese Person ist keine Vorlage verfügbar.")
            has_override = false
        end

        respond(success: true,
                template: template,
                has_override: has_override,
                username: user_info['username'],
                display_name: user_info['display_name'])
    end

    # Save a manual override for a user. Locks the user's own data editing and makes
    # the entry independent of the variant design.
    post '/api/yearbook/override/save' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        # The edited template inlines images as data URLs and can grow several MB.
        data = parse_request_data(
            required_keys: [:target_username, :template],
            max_body_length: 50_000_000,
            max_string_length: 50_000_000
        )
        username = data[:target_username].to_s.strip
        assert(username =~ YEARBOOK_USERNAME_FORMAT, "Ungültiger Benutzername")
        template = data[:template]
        assert(template.is_a?(Hash) && template['schemas'].is_a?(Array), "Ungültige Vorlage")

        user_exists = neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username}) RETURN u.username AS username
        END_OF_QUERY
        assert(!user_exists.empty?, "Benutzer nicht gefunden")

        template['basePdf'] ||= YEARBOOK_DEFAULT_BASE_PDF
        payload = { 'username' => username, 'updated_at' => yearbook_timestamp, 'template' => template }

        FileUtils.mkdir_p(YEARBOOK_OVERRIDE_DIR)
        File.write(yearbook_override_path(username), JSON.pretty_generate(payload))

        neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username}) SET u.yearbook_manual_override = true
        END_OF_QUERY

        log("Jahrbuch-Eintrag von #{username} manuell überschrieben durch #{@session_user[:username]}")
        respond(success: true, message: "Manuelles Design gespeichert. Der Eintrag ist jetzt gesperrt.")
    end

    # Remove the manual override → the entry is auto-generated from the variant
    # design again and the user may edit their data once more.
    post '/api/yearbook/override/reset' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        data = parse_request_data(required_keys: [:target_username])
        username = data[:target_username].to_s.strip
        assert(username =~ YEARBOOK_USERNAME_FORMAT, "Ungültiger Benutzername")

        path = yearbook_override_path(username)
        File.delete(path) if File.exist?(path)
        neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username}) REMOVE u.yearbook_manual_override
        END_OF_QUERY

        log("Manuelles Jahrbuch-Design für #{username} zurückgesetzt durch #{@session_user[:username]}")
        respond(success: true, message: "Auf automatisches Design zurückgesetzt. Der Eintrag ist wieder freigegeben.")
    end

    # ----- mark an entry as finished / abgeschlossen -----------------------
    #
    # Unlike the manual override, finalising leaves the design untouched (the entry
    # keeps rendering from its variant) and only freezes the student's editing. It
    # is meant for the common "this entry is done, lock it" workflow and is trivially
    # reversible via /finalize/reset. The lock effect on the student is identical to
    # a manual override (see yearbook_user_locked?).

    # Mark a user's entry as finished. yearbook_manage only.
    post '/api/yearbook/finalize/set' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        data = parse_request_data(required_keys: [:target_username])
        username = data[:target_username].to_s.strip
        assert(username =~ YEARBOOK_USERNAME_FORMAT, "Ungültiger Benutzername")

        user_exists = neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username}) RETURN u.username AS username
        END_OF_QUERY
        assert(!user_exists.empty?, "Benutzer nicht gefunden")

        neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username}) SET u.yearbook_finalized = true
        END_OF_QUERY

        log("Jahrbuch-Eintrag von #{username} abgeschlossen durch #{@session_user[:username]}")
        respond(success: true, message: "Eintrag abgeschlossen. Der Eintrag ist jetzt gesperrt.")
    end

    # Re-open a finished entry → the student may edit their data again. yearbook_manage only.
    post '/api/yearbook/finalize/reset' do
        require_user!
        require_user_with_permission!("yearbook_manage")

        data = parse_request_data(required_keys: [:target_username])
        username = data[:target_username].to_s.strip
        assert(username =~ YEARBOOK_USERNAME_FORMAT, "Ungültiger Benutzername")

        neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username}) REMOVE u.yearbook_finalized
        END_OF_QUERY

        log("Jahrbuch-Eintrag von #{username} wieder freigegeben durch #{@session_user[:username]}")
        respond(success: true, message: "Eintrag wieder freigegeben. Der Eintrag ist wieder bearbeitbar.")
    end

end
