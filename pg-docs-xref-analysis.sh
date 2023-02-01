#!/bin/bash

#
# pg-docs-xref link analysis
# ==========================
#
# Backstory
# ---------
#
# xrefs are the way that our documentation can direct a reader to another part
# of the documentation. They point to a specific id found in another file
# in the source tree. By convention, all files have one refentry id for the
# entire page, but may also have other ids for specific sections within the
# page.
#
# References to whole pages make sense when the referenced page is small.
# However, as the referened page grows in size, not all portions will apply
# for the reference, cluttering the reader experience and making the reference
# less valuable. Additionally, references to a whole page are considered
# more suspicious when more granular refentries exist within that same page.
#
# Goal
# ----
#
# This script is intended to provide an ongoing way to determine which files
# should be considered for creating more granular refentries. It identifies
# files that have at least one external reference to the first (possibly only)
# refentry, and then ranks those files by a formula that reflects the
# likelihood that the file needs more granular refentries, or (more
# importantly) already has more granular entries and they just aren't being
# used.
#
# Future Directions
# -----------------
#
# More refined statistical inferences in relation to the skew of references
# within a page.
#
# Some filter on the pages/references that allows a graphviz SVG that is small
# enough to be usable by humans.
#
# Configurable pg_doc_dir, line count filter, etc.
#
# We may want to add a filter to exclude files below a threshold line count,
# because small pages by definition are fairly focused in their topic, and
# the burden of reading the whole page is small.
#
# After this report has been used a few times, it will become obvious that a
# few stubborn pages continue to rank high despite having been throughly
# reviewed. We may want a mechanism to exclude them from the report.
#
# Developer Notes
# ---------------
#
# The choice of perl regexps in grep is not ideal. However, xsltproc and xq
# were emitting errors about claims of unmatched tags, extra characters
# outside of tags, and various HTMLisms like &mdash; and other &-chars.
#
# The choice of weighting/ranking (number of references * size of file in
# lines) is far from scientific, it was simply the first metric that came
# to mind. The additional multiplier to highlight pages that already have
# multiple refentries was an afterthought, and was added on to avoid
# excluding pages with multiple refentries entirely.
#
# The choice of 200 lines as the minimum threshold for warranting more
# refentries was based on sampling a few files and seeing how many
# ideas were expressed in that much space.
#
# SQLite may seem like an odd choice given the subject matter, but it is a
# quick way to correlate throwaway data. It is, however, lacking in advanced
# statitistical functions.
#
# The file ecpg.sgml does not appear to have a top-level refentry which skews
# the rank for what otherwise appears to be a highly granular xref.
#

set -eu

#
# location of the PG source tree sgml directory, change to suit
# local configuration
#
pg_doc_dir="${HOME}/src/postgres/doc/src/sgml"

#
# get a line count for every sgml file
#
wc --lines "${pg_doc_dir}"/*.sgml "${pg_doc_dir}"/ref/*.sgml \
    | grep -v 'total$' \
    | sed -e 's/^ *//' -e "s#${pg_doc_dir}/##" -e 's/ /\t/' \
    > file-line-counts.tsv

#
# collect all times an id is referenced in a file
#
grep --only-matching --perl-regexp '(?<=linkend=").*?(?=")' "${pg_doc_dir}"/*.sgml "${pg_doc_dir}"/ref/*.sgml \
    | sed -e "s#${pg_doc_dir}/##" -e 's/:/\t/' \
    > all-references.tsv

#
# map refentries to file names, numbering them so we know which was first
#
grep --only-matching --perl-regexp '(?<=id=").*?(?=")' "${pg_doc_dir}"/*.sgml "${pg_doc_dir}"/ref/*.sgml \
    | sed -e "s#${pg_doc_dir}/##" -e 's/:/\t/' \
    | nl \
    > file-anchors.tsv

#
# combine the extrated data into a weighted report
#
sqlite3 << EOF

.mode tabs

CREATE TABLE file_line_counts (
    num_lines integer,
    file_name text PRIMARY KEY
);

.import file-line-counts.tsv file_line_counts

CREATE TABLE all_references (
    file_name text NOT NULL,
    link_name text NOT NULL
);

.import all-references.tsv all_references

--
-- Anchors are supposed to be unique throughout the document tree, so this
-- table load will fail if that is not true.
--
CREATE TABLE file_anchors (
    link_rank integer, -- currently unused, useful if the first link in a file is important
    file_name text,
    link_name text PRIMARY KEY
);

.import file-anchors.tsv file_anchors

ALTER TABLE all_references ADD COLUMN internal_flag integer DEFAULT 0;

UPDATE all_references
SET internal_flag = (all_references.file_name = fa.file_name)
FROM file_anchors AS fa
WHERE fa.link_name = all_references.link_name;

CREATE TABLE file_info (
    file_name text PRIMARY KEY,
    num_lines integer NOT NULL,
    num_anchors integer NOT NULL,
    num_anchors_referenced integer NOT NULL,
    num_anchors_not_referenced integer NOT NULL,
    num_anchors_referenced_internal integer NOT NULL,
    num_anchors_referenced_external integer NOT NULL,
    num_references integer NOT NULL,
    num_references_internal integer NOT NULL,
    num_references_external integer NOT NULL,
    num_links integer NOT NULL,
    num_links_internal INTEGER NOT NULL,
    num_links_external INTEGER NOT NULL,
    num_distinct_links integer NOT NULL,
    num_distinct_links_internal integer NOT NULL,
    num_distinct_links_external integer NOT NULL
);

INSERT INTO file_info
WITH inbound AS (
    SELECT
        fa.file_name,
        COUNT(DISTINCT fa.link_name) AS num_anchors,
        COUNT(DISTINCT fa.link_name) FILTER (WHERE ar.link_name IS NOT NULL) AS num_anchors_referenced,
        COUNT(DISTINCT fa.link_name) FILTER (WHERE ar.link_name IS NULL) AS num_anchors_not_referenced,
        COUNT(DISTINCT fa.link_name) FILTER (WHERE ar.internal_flag = 1) AS num_anchors_referenced_internal,
        COUNT(DISTINCT fa.link_name) FILTER (WHERE ar.internal_flag = 0) AS num_anchors_referenced_external,
        COUNT(*) AS num_references,
        COUNT(*) FILTER (WHERE ar.internal_flag = 1) AS num_references_internal,
        COUNT(*) FILTER (WHERE ar.internal_flag = 0) AS num_references_external
    FROM file_anchors AS fa
    LEFT JOIN all_references ar ON ar.link_name = fa.link_name
    GROUP BY fa.file_name
),
outbound AS (
    SELECT
        ar.file_name,
        COUNT(*) AS num_links,
        COUNT(*) FILTER (WHERE ar.internal_flag = 1) AS num_links_internal,
        COUNT(*) FILTER (WHERE ar.internal_flag = 0) AS num_links_external,
        COUNT(DISTINCT ar.link_name) AS num_distinct_links,
        COUNT(DISTINCT ar.link_name) FILTER (WHERE ar.internal_flag = 1) AS num_distinct_links_internal,
        COUNT(DISTINCT ar.link_name) FILTER (WHERE ar.internal_flag = 0) AS num_distinct_links_external
    FROM all_references ar
    GROUP BY ar.file_name
)
SELECT
    flc.file_name,
    flc.num_lines,
    COALESCE(i.num_anchors, 0) AS num_anchors,
    COALESCE(i.num_anchors_referenced, 0) AS num_anchors_referenced,
    COALESCE(i.num_anchors_not_referenced, 0) AS num_anchors_not_referenced,
    COALESCE(i.num_anchors_referenced_internal, 0) AS num_anchors_referenced_internal,
    COALESCE(i.num_anchors_referenced_external, 0) AS num_anchors_referenced_external,
    COALESCE(i.num_references, 0) AS num_references,
    COALESCE(i.num_references_internal, 0) AS num_references_internal,
    COALESCE(i.num_references_external, 0) AS num_references_external,
    COALESCE(o.num_links, 0) AS num_links,
    COALESCE(o.num_links_internal, 0) AS num_links_internal,
    COALESCE(o.num_links_external, 0) AS num_links_external,
    COALESCE(o.num_distinct_links, 0) AS num_distinct_links,
    COALESCE(o.num_distinct_links_internal, 0) AS num_distinct_links_internal,
    COALESCE(o.num_distinct_links_external, 0) AS num_distinct_links_external
FROM file_line_counts AS flc
LEFT JOIN inbound AS i ON i.file_name = flc.file_name
LEFT JOIN outbound AS o ON o.file_name = flc.file_name;

.mode column

.print
.print ================================================================
.print Files that have only one anchor but are referenced several times
.print Ranked by file size * number of references.
.print This may be an indicator that the subsections of the page could
.print use their own ids.
.print ================================================================
.print
.width 0 -12 -7 -15
SELECT
    fi.file_name AS "File Name",
    fi.num_references AS "# References",
    fi.num_lines AS "# Lines",
    fi.num_references * fi.num_lines AS "Reference Score"
FROM file_info AS fi
WHERE fi.num_links = 1
AND fi.num_references >= 3
AND fi.num_lines >= 200
ORDER BY "Reference Score" DESC;

.print
.print ========================================================================
.print Files with a high % of unreferenced anchors but not just one referenced.
.print This may be an indication that ids have been added to a page but
.print references to that page have not been updated to more specific sections.
.print ========================================================================
.print
.width 0 -12 -7 -18 -20 -20
WITH pcts AS (
    SELECT
        fi.file_name,
        fi.num_references,
        fi.num_lines,
        fi.num_anchors,
        fi.num_anchors_referenced,
        CAST(100 AS REAL) * fi.num_anchors_referenced / fi.num_anchors AS pct_anchors_referenced
    FROM file_info AS fi
    WHERE fi.num_anchors > 1
    AND fi.num_references >= 3
    AND fi.num_anchors_referenced > 1
    AND fi.num_anchors_referenced < fi.num_anchors
    AND fi.num_lines >= 200
)
SELECT
    p.file_name AS "File Name",
    p.num_references AS "# References",
    p.num_lines AS "# Lines",
    p.num_anchors AS "# Anchors",
    p.num_anchors_referenced AS "# Anchors Referenced",
    printf('%.2f', p.pct_anchors_referenced) AS "% Anchors Referenced"
FROM pcts AS p
ORDER BY p.pct_anchors_referenced, p.num_anchors DESC;

.print
.print ====================================================================
.print Files that have more than one anchor but only one link is referenced
.print Ranked by file size * number of references.
.print ====================================================================
.print

.width 0 -12 -9 0, -15
SELECT
    fi.file_name AS "File Name",
    fi.num_references AS "# References",
    fi.num_anchors AS "# Anchors",
    (   SELECT ar.link_name
        FROM all_references AS ar
        WHERE ar.file_name = fi.file_name
        LIMIT 1) AS "Only Anchor Referenced",
    fi.num_anchors * fi.num_references AS "Reference Score"
FROM file_info AS fi
WHERE fi.num_anchors_referenced = 1
AND fi.num_anchors > 1
AND fi.num_references > 1
ORDER BY "Reference Score" DESC;

.print
.print =====================================================================
.print Generating document-graph-stats.dot
.print Currently, the dotfile generated is too large to generate into a
.print human-readable SVG file, but the dotfile is provided anyway so as to
.print document how such a thing would be generated
.print =====================================================================
.print

.output document-graph-stats.dot
.mode list
.headers off

.print 'digraph {'

CREATE VIEW graphviz_nodes
AS
SELECT
    replace(replace(replace(fi.file_name, '-', '_'), '/', '_'), '.sgml', '') AS digraph_name,
    fi.file_name
FROM file_info AS fi;

CREATE VIEW graphviz_edges
AS
SELECT
    a.digraph_name AS from_node,
    a.digraph_name AS to_node,
    COUNT(*) AS edge_weight
FROM graphviz_nodes AS a
JOIN all_references AS ar ON ar.file_name = a.file_name
JOIN file_anchors AS fa ON fa.link_name = ar.link_name
JOIN graphviz_nodes AS b ON b.file_name = fa.file_name
WHERE a.file_name != b.file_name
GROUP BY from_node, to_node;

SELECT n.digraph_name || ' [ label="' || n.file_name || '" ]'
FROM graphviz_nodes AS n;

SELECT e.from_node || ' -> ' || e.to_node || ';'
FROM graphviz_edges AS e
ORDER BY e.edge_weight DESC;

.print '}'

EOF
