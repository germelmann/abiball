#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Whole-yearbook PDF export worker.
#
# This runs INSIDE the ruby container (it is launched by export-yearbook-pdf.rb via
# `./config.rb exec`). It renders every student in its OWN low-memory Node pass to a
# temporary file and then stitches all the finished PDFs together into one document.
#
# Why this design: the /api/yearbook/export_pdf route builds every student's jobs
# (with images inlined as multi-MB base64 data URLs) and hands them to a single Node
# process at once. For a full class that easily reaches multiple GB of resident
# memory and can take the whole web server down. Rendering one student at a time —
# and letting Node write each PDF straight to disk so the bytes never live in this
# Ruby process — keeps peak memory bounded to a single student. The final merge only
# ever touches already-compressed, image-embedded PDFs (chunked to stay small).
#
# Usage (inside the container):
#   ruby /src/scripts/export_yearbook_worker.rb [--out PATH] [--batch N]
#        [--merge-chunk N] [--limit N] [--keep-temp]

require 'fileutils'
require 'optparse'

Dir.chdir('/src/ruby')

# Loading the app gives us the exact same rendering pipeline the server uses
# (variant selection, accent colours, blocks, comments, manual overrides). Its
# configure block chatters a couple of lines to STDERR on boot — harmless here.
require './main.rb'

options = { out: nil, batch: 1, merge_chunk: 25, limit: nil, keep_temp: false }
OptionParser.new do |o|
  o.banner = 'Usage: export_yearbook_worker.rb [options]'
  o.on('--out PATH', 'Zieldatei (Standard: /raw/jahrbuch_full_<zeit>.pdf)') { |v| options[:out] = v }
  o.on('--batch N', Integer, 'Schüler pro Render-Aufruf (Standard 1, mehr = schneller, mehr RAM)') { |v| options[:batch] = [v, 1].max }
  o.on('--merge-chunk N', Integer, 'PDFs pro Merge-Schritt (Standard 25)') { |v| options[:merge_chunk] = [v, 2].max }
  o.on('--limit N', Integer, 'Nur die ersten N Schüler exportieren (Test)') { |v| options[:limit] = v }
  o.on('--keep-temp', 'Temporäre Einzel-PDFs nicht löschen') { options[:keep_temp] = true }
end.parse!(ARGV)

def say(msg)   = ($stdout.print(msg); $stdout.flush)
def sayln(msg = '') = ($stdout.puts(msg); $stdout.flush)

def fmt_bytes(n)
  return "#{n} B" if n < 1024
  return format('%.1f KB', n / 1024.0) if n < 1024 * 1024
  format('%.1f MB', n / (1024.0 * 1024))
end

def fmt_duration(seconds)
  s = seconds.round
  format('%d:%02d', s / 60, s % 60)
end

def pages_in_jobs(jobs)
  (jobs || []).sum { |j| ((j['template'] || {})['schemas'] || []).length }
end

# Merge a list of PDF files into final_out, chunked so no single Node merge call
# loads too many documents at once. Repeats in levels until one file remains.
def merge_all(app, part_files, final_out, chunk, tmp_dir)
  if part_files.empty?
    return nil
  elsif part_files.size == 1
    FileUtils.cp(part_files.first, final_out)
    return final_out
  end

  current = part_files
  level = 0
  while current.size > 1
    groups = current.each_slice(chunk).to_a
    sayln "  Zusammenführen (Ebene #{level + 1}): #{current.size} → #{groups.size} Datei(en) …"
    nxt = []
    groups.each_with_index do |grp, gi|
      if grp.size == 1
        nxt << grp.first
      else
        out = File.join(tmp_dir, format('merge_l%d_%05d.pdf', level, gi))
        app.merge_yearbook_pdf_files(grp, out)
        nxt << out
      end
    end
    current = nxt
    level += 1
  end

  FileUtils.cp(current.first, final_out)
  final_out
end

started_at = Time.now
app = Main.allocate # bare instance: we only need its rendering helpers, no request context

variant_set = app.load_yearbook_variant_set

targets = app.send(:neo4j_query, <<~END_OF_QUERY)
  MATCH (u:User)
  WHERE (u)-[:HAS_YEARBOOK_PROFILE]->() OR (u)-[:HAS_YEARBOOK_ENTRY]->()
  OPTIONAL MATCH (u)-[:IS_SCHUELER]->(s:Schueler)
  RETURN u.username AS username, COALESCE(s.name, u.name) AS display_name
  ORDER BY display_name
END_OF_QUERY
targets = targets.to_a
targets = targets.first(options[:limit]) if options[:limit]

if targets.empty?
  sayln 'Keine Jahrbuch-Einträge gefunden — nichts zu exportieren.'
  app.cleanup_neo4j rescue nil
  exit 0
end

final_out = options[:out] || "/raw/jahrbuch_full_#{Time.now.strftime('%Y%m%d_%H%M%S')}.pdf"
tmp_dir = "/raw/.yb_export_tmp_#{Process.pid}_#{Time.now.to_i}"
FileUtils.mkdir_p(tmp_dir)

# Encode the fonts once (a few hundred KB of base64) and reuse for every render.
fonts = app.yearbook_fonts_payload

total = targets.size
sayln "Jahrbuch-Export: #{total} Eintrag/Einträge"
sayln "Ziel: #{final_out}"
sayln "Render-Batchgröße: #{options[:batch]}, Merge-Chunk: #{options[:merge_chunk]}"
sayln '-' * 60

part_files = []
rendered = 0
skipped  = 0
failed   = 0
processed = 0

targets.each_slice(options[:batch]).with_index do |slice, slice_idx|
  slice_jobs = []
  slice_prepared = 0

  slice.each do |row|
    processed += 1
    username = row['username']
    name = row['display_name'].to_s
    say format('[%3d/%3d] %s (%s) … ', processed, total, name, username)
    begin
      jobs = app.build_yearbook_jobs_for_user(username, variant_set)
      if jobs.nil? || jobs.empty?
        sayln 'übersprungen (keine Vorlage/Daten)'
        skipped += 1
        next
      end
      slice_jobs.concat(jobs)
      p = pages_in_jobs(jobs)
      sayln "vorbereitet (#{p} Seiten)"
      slice_prepared += 1
    rescue => e
      sayln "FEHLER: #{e.message}"
      failed += 1
    end
  end

  next if slice_jobs.empty?

  part = File.join(tmp_dir, format('part_%05d.pdf', slice_idx))
  begin
    say "  → rendere #{slice_jobs.size} Seiten-Job(s) … "
    app.render_yearbook_pdf_jobs_to_file(slice_jobs, part, fonts)
    part_files << part
    rendered += slice_prepared
    sayln "ok (#{fmt_bytes(File.size(part))})"
  rescue => e
    sayln "FEHLER beim Rendern: #{e.message}"
    failed += slice_prepared
  end

  # Release the (large) per-slice job structures before the next slice.
  slice_jobs = nil
  GC.start
end

sayln '-' * 60

if part_files.empty?
  sayln 'Es konnte kein einziger Eintrag gerendert werden — kein PDF erzeugt.'
  FileUtils.rm_rf(tmp_dir) unless options[:keep_temp]
  app.cleanup_neo4j rescue nil
  exit 1
end

sayln "Führe #{part_files.size} Teil-PDF(s) zusammen …"
merge_all(app, part_files, final_out, options[:merge_chunk], tmp_dir)

final_size = File.exist?(final_out) ? File.size(final_out) : 0
unless options[:keep_temp]
  FileUtils.rm_rf(tmp_dir)
else
  sayln "Temp-Verzeichnis behalten: #{tmp_dir}"
end

app.cleanup_neo4j rescue nil

sayln '=' * 60
sayln "Fertig in #{fmt_duration(Time.now - started_at)}."
sayln "Gerendert: #{rendered}, übersprungen: #{skipped}, Fehler: #{failed}"
sayln "Datei: #{final_out} (#{fmt_bytes(final_size)})"
sayln '(Auf dem Host liegt sie unter <DATA_PATH>/raw/' + File.basename(final_out) + ', sofern --out im /raw liegt.)'
