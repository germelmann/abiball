# Jahrbuch-Hintergrund-PDFs

Lege hier `.pdf`-Dateien ab. Sie tauchen automatisch in der
Variant-Leiste des Template-Designers (`/jahrbuch_template_edit`)
als Auswahlmöglichkeit auf — pro Variante kannst du eine PDF
als Hintergrund festlegen.

Die PDF-Bytes bleiben **nicht** im gespeicherten Template
(nur der Dateiname); Ruby liest die Datei zur Render-Zeit und
schiebt sie als `basePdf` in die PDF-Pipeline. Tauschst du die
Datei aus, ist beim nächsten Export die neue Version aktiv.

A4 (210×297 mm) hochkant empfohlen, damit deine im Designer
positionierten Felder zur Seitendimension passen.
