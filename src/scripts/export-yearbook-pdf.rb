#!/usr/bin/env ruby
# Exportiert das komplette Jahrbuch als EINE PDF-Datei — speicherschonend und mit
# Fortschrittsanzeige. Jeder Schüler wird einzeln gerendert (damit der Server nicht
# wegen RAM stirbt) und am Ende werden alle Teil-PDFs zusammengeführt.
#
# Der eigentliche Worker läuft im laufenden ruby-Container. Die fertige Datei landet
# standardmäßig in <DATA_PATH>/raw/jahrbuch_full_<zeit>.pdf (im Container: /raw/...).
#
# Beispiele (aus src/scripts heraus ausführen):
#   ./export-yearbook-pdf.rb
#   ./export-yearbook-pdf.rb --out /raw/jahrbuch.pdf
#   ./export-yearbook-pdf.rb --limit 5            # nur die ersten 5 (Test)
#   ./export-yearbook-pdf.rb --batch 3            # 3 Schüler pro Render-Aufruf
#
# Weitere Optionen: --merge-chunk N, --keep-temp  (siehe export_yearbook_worker.rb)

require 'shellwords'

args = ARGV.map { |a| Shellwords.escape(a) }.join(' ')
system("cd ../.. && ./config.rb exec ruby ruby /src/scripts/export_yearbook_worker.rb #{args}")
