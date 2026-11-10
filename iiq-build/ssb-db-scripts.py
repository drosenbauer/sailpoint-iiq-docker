#!/usr/bin/env python3
"""Runs the custom database scripts from an SSB's db/ folder against IIQ's database.

Usage: ssb-db-scripts.py --db mssql|mysql [--source-url <jdbc url>] [--dry-run] <db folder>

SSB scripts are written for whatever database the customer runs IIQ on: usually
Oracle, sometimes PostgreSQL, SQL Server or MySQL. A script already written for
this container's database runs as-is. Anything else is converted. This covers
what SSB scripts commonly do (tables, indexes, inserts, renames, synonyms,
sequences, identity columns), not every feature of every database: procedural
code (PL/SQL, T-SQL, PL/pgSQL) is skipped with a message.

Which schema: custom tables belong in the plugin schema (identityiqPlugin), so
scripts run there, except a script that creates, alters or drops something on
IIQ's own spt_ tables or names the identityiq schema as its target (columns and
indexes for extended attributes, for example). That script runs in identityiq.
Only the object a statement changes counts: a script that grants on or selects
from identityiq.spt_identity still runs in the plugin schema.

Which files run: .sql files, and files named for a database (.oracle,
.postgresql, .sqlserver or .mssql, .mysql). When a folder has the same script
for several databases, the version for this database wins, then Oracle. The
database a .sql file was written for is worked out from its syntax; if nothing
in it gives that away, from --source-url (the SSB's original JDBC URL), and
failing that, Oracle.

Run order: a script that uses a table another script creates runs after that
script. Otherwise, scripts run in alphabetical order by path.

Each statement runs on its own, and a failure doesn't stop the rest. SSB
scripts often include changes meant for an older copy of the database (renamed
tables, added columns) that fail harmlessly on a new one.

Connection settings come from the container's environment. SQL Server:
MSSQL_HOST, MSSQL_USER and MSSQL_PASS, connecting as MSSQL_USER to the
identityiq database or as identityiqPlugin to the identityiqPlugin database, so
that new objects land in that login's default schema. MySQL: MYSQL_HOST and
MYSQL_ROOT_PASSWORD, using the identityiq database or PLUGINDB (default
identityiqPlugin).
"""

import argparse
import os
import re
import subprocess
import sys

I = re.IGNORECASE
S = re.IGNORECASE | re.DOTALL
M = re.IGNORECASE | re.MULTILINE

EXTENSIONS = {'.oracle': 'oracle', '.postgresql': 'postgres', '.postgres': 'postgres', '.pgsql': 'postgres',
              '.sqlserver': 'mssql', '.mssql': 'mssql', '.mysql': 'mysql', '.sql': None}
DB_NAMES = {'oracle': 'Oracle', 'postgres': 'PostgreSQL', 'mssql': 'SQL Server', 'mysql': 'MySQL'}

# Syntax that gives away which database a .sql script was written for
TELLS = {
    'oracle': r'\bn?varchar2\b|\bnumber\s*\(|\bsys(date|timestamp)\b|\bsys_guid\b|\bclob\b|^\s*/\s*$'
              r'|\bnocache\b|\.nextval\b|\bsynonym\b|\b(?:char|byte)\s*\)',
    'postgres': r'\b(?:big)?serial\b|\btimestamptz\b|\bbytea\b|::\w+|\bgen_random_uuid\b|\$\$'
                r'|\bjsonb\b|\bon\s+conflict\b|\bcharacter\s+varying\b',
    'mssql': r'^\s*go\s*$|\[\w+\]|\b(?:n?varchar|varbinary)\s*\(\s*max\b|\bidentity\s*\(\s*\d+\s*,|\bdatetime2\b'
             r'|\bgetdate\s*\(|\bnewid\s*\(|\buniqueidentifier\b|\bdbo\.|\bnonclustered\b',
    'mysql': r'`\w+`|\bauto_increment\b|\bengine\s*=|\blongtext\b|\bunsigned\b|\bdefault\s+charset\b',
}

# A table or other object name, optionally schema-qualified and/or quoted
PART = r'(?:"[^"]+"|\[[^\]]+\]|`[^`]+`|[\w$#]+)'
NAME = r'(' + PART + r'(?:\.' + PART + r')?)'

# Statements that start a procedural block, whose semicolons don't end the statement
BLOCK = re.compile(r'\s*(create\s+(or\s+(replace|alter)\s+)?((editionable|noneditionable|definer\s*=\s*\S+)\s+)?'
                   r'(trigger|procedure|proc|function|package|type)\b|begin\b|declare\b|do\b|if\b)', I)
SQLPLUS = re.compile(r'(set|prompt|spool|whenever|exit|quit|rem|remark|show|define|undefine|connect)\b|@', I)

CREATES = [re.compile(p.replace('NAME', NAME), M) for p in (
    r'^create\s+(?:global\s+temporary\s+)?table\s+(?:if\s+not\s+exists\s+)?NAME',
    r'^create\s+(?:or\s+(?:replace|alter)\s+)?(?:(?:no)?force\s+)?view\s+NAME',
    r'^create\s+(?:or\s+replace\s+)?(?:public\s+)?synonym\s+NAME',
    r'^create\s+sequence\s+(?:if\s+not\s+exists\s+)?NAME',
)]
USES = [re.compile(p.replace('NAME', NAME), M) for p in (
    r'^alter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?NAME',
    r'^insert\s+(?:ignore\s+)?into\s+NAME',
    r'^update\s+NAME',
    r'^delete\s+(?:from\s+)?NAME',
    r'^merge\s+into\s+NAME',
    r'^rename\s+NAME',
    r'\bon\s+NAME\s*\(',
    r'\breferences\s+NAME',
    r'\bsynonym\s+\S+\s+for\s+NAME',
    r'\b(?:from|join)\s+NAME',
    r'NAME\.nextval\b',
    r"\bnextval\s*\(\s*'NAME'",
)]

# The object a DDL statement changes, to tell whether it belongs to IIQ
CHANGES = [re.compile(p.replace('NAME', NAME), I) for p in (
    r'alter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?NAME',
    r'create\s+(?:unique\s+|bitmap\s+)?index\s+\S+\s+on\s+NAME',
    r'create\s+(?:global\s+temporary\s+)?table\s+(?:if\s+not\s+exists\s+)?NAME',
    r'create\s+(?:or\s+(?:replace|alter)\s+)?(?:(?:no)?force\s+)?view\s+NAME',
    r'create\s+(?:or\s+replace\s+)?trigger\s+\S+\s+.*?\bon\s+NAME',
    r'drop\s+(?:table|view|index)\s+(?:if\s+exists\s+)?NAME',
    r'(?:rename|truncate\s+table)\s+NAME',
)]

# Words that work as column names in the source databases but are reserved in
# the target, limited to ones that plausibly name a column
RESERVED = {
    'mssql': set('''identity key plan percent rule open close external top function read file merge
        return schema statistics current full left right double print save backup transaction tran
        proc pivot unpivot cursor fetch browse bulk dump deny exec execute kill national restore
        restrict revert textsize truncate contains convert cross inner outer join holdlock lineno
        offsets rowcount nocheck freetext disk clustered nonclustered checkpoint compute coalesce
        collate break continue goto while end begin'''.split()),
    'mysql': set('''key keys rank groups condition function row rows interval range release usage read
        match mod schema return system window lead lag empty signal leave loop repeat maxvalue div
        change describe ignore kill limit lines load lock long option purge show spatial sql undo
        use write both call cascade cursor delayed each exit fetch force generated get inner left
        right linear natural out outer precision reads require stored virtual lateral recursive
        explain separator starting terminated unsigned while continue before analyze'''.split()),
}


# ---------------------------------------------------------------------------
# Finding, splitting and ordering scripts

def find_scripts(root, db):
    """Returns ([(path, extension dialect or None for .sql)], [paths skipped])"""
    groups = {}
    for dirpath, dirnames, filenames in os.walk(root):
        for filename in filenames:
            stem, ext = os.path.splitext(filename)
            if ext.lower() in EXTENSIONS:
                rel = os.path.relpath(os.path.join(dirpath, filename), root)
                groups.setdefault((os.path.dirname(rel), stem.lower()), {})[EXTENSIONS[ext.lower()]] = rel
    chosen, skipped = [], []
    for versions in groups.values():
        for dialect in (db, 'oracle', None, 'postgres', 'mssql', 'mysql'):
            if dialect in versions:
                chosen.append((versions[dialect], dialect))
                skipped.extend(p for d, p in versions.items() if d != dialect)
                break
    return chosen, sorted(skipped)


def detect_dialect(text, fallback):
    """The database a .sql script was most likely written for"""
    scores = {d: len(re.findall(p, text, M)) for d, p in TELLS.items()}
    best = max(scores, key=lambda d: (scores[d], d == fallback))
    return best if scores[best] else fallback


def url_dialect(url):
    """The database a JDBC URL points to, or None"""
    m = re.match(r'\s*jdbc:(oracle|postgresql|sqlserver|jtds:sqlserver|mysql|mariadb):', url or '', I)
    if m:
        return {'oracle': 'oracle', 'postgresql': 'postgres', 'mysql': 'mysql', 'mariadb': 'mysql'}.get(m.group(1).lower(), 'mssql')
    return None


def split_statements(text, dialect):
    """Splits a script into statements and drops comments. Statements end at a
    semicolon, or at a line holding only "/" (Oracle) or "GO" (SQL Server).
    Procedural blocks only end at "/" or "GO", or at the end of the file."""
    statements, buf = [], ''
    quote = None        # the open quote: ' or a PostgreSQL $tag$
    in_comment = False
    for line in text.splitlines():
        bare = line.strip()
        if not quote and not in_comment:
            if bare == '/' or bare.upper() == 'GO':
                statements.append(buf)
                buf = ''
                continue
            if dialect == 'oracle' and not buf.strip() and SQLPLUS.match(bare):
                continue
        i = 0
        while i < len(line):
            ch, two = line[i], line[i:i + 2]
            if in_comment:
                if two == '*/':
                    in_comment = False
                    i += 1
            elif quote:
                if line.startswith(quote, i):
                    buf += quote
                    i += len(quote)
                    quote = None
                    continue
                buf += ch
            elif two == '--':
                break
            elif two == '/*':
                in_comment = True
                i += 1
            elif ch == "'":
                quote = "'"
                buf += ch
            elif ch == '$' and dialect == 'postgres' and re.match(r'\$\w*\$', line[i:]):
                quote = re.match(r'\$\w*\$', line[i:]).group(0)
                buf += quote
                i += len(quote)
                continue
            elif ch == ';' and not BLOCK.match(buf):
                statements.append(buf)
                buf = ''
            else:
                buf += ch
            i += 1
        buf += '\n'
    statements.append(buf)
    return [s.strip() for s in statements if s.strip()]


def mask_literals(sql):
    """Swaps string literals for placeholders so conversions can't touch them.
    Returns the masked SQL and a function that puts the literals back."""
    literals = []

    def stash(m):
        literals.append(m.group(0))
        return '\x00%d\x00' % (len(literals) - 1)

    masked = re.sub(r"'(?:[^']|'')*'|\$(\w*)\$.*?\$\1\$", stash, sql, flags=re.DOTALL)
    return masked, lambda s: re.sub(r'\x00(\d+)\x00', lambda m: literals[int(m.group(1))], s)


def bare_name(raw):
    return re.split(r'\.(?=[^.]*$)', raw)[-1].strip('"[]`').lower()


def object_names(stmt):
    """(names the statement creates, names it uses)"""
    masked, _ = mask_literals(stmt)
    creates = {bare_name(m.group(1)) for p in CREATES for m in p.finditer(masked)}
    uses = {bare_name(m.group(1)) for p in USES for m in p.finditer(masked)}
    return creates, uses


def changes_iiq_object(stmt):
    """Whether a statement creates, alters or drops one of IIQ's own objects: an
    spt_ table, or anything qualified with the identityiq schema"""
    masked, _ = mask_literals(stmt)
    for p in CHANGES:
        m = p.match(masked)
        if m:
            parts = [part.strip('"[]`').lower() for part in m.group(1).split('.')]
            return parts[-1].startswith('spt_') or (len(parts) > 1 and parts[0] == 'identityiq')
    return False


def plugin_database(db):
    """The plugin database's name. The MySQL setup takes it from PLUGINDB; the
    SQL Server setup always uses identityiqPlugin."""
    name = os.environ.get('PLUGINDB', '') if db == 'mysql' else ''
    return name if re.fullmatch(r'\w+', name) else 'identityiqPlugin'


def order_scripts(scripts):
    """scripts: {path: (creates, uses)}. Returns paths so that each script comes
    after the scripts that create what it uses, alphabetical otherwise."""
    creators = {}
    for path, (creates, _) in scripts.items():
        for name in creates:
            creators.setdefault(name, set()).add(path)
    deps = {}
    for path, (creates, uses) in scripts.items():
        deps[path] = set()
        for name in uses - creates:
            deps[path] |= creators.get(name, set()) - {path}

    order, remaining = [], sorted(scripts, key=str.lower)
    while remaining:
        # The first script whose dependencies have all run; if none (a cycle), just the first
        nxt = next((p for p in remaining if deps[p] <= set(order)), remaining[0])
        order.append(nxt)
        remaining.remove(nxt)
    return order


# ---------------------------------------------------------------------------
# Converting statements

def split_top_level(text):
    """Splits on commas that aren't inside parentheses"""
    parts, depth, cur = [], 0, ''
    for ch in text:
        if ch == ',' and depth == 0:
            parts.append(cur)
            cur = ''
            continue
        depth += (ch == '(') - (ch == ')')
        cur += ch
    parts.append(cur)
    return [p.strip() for p in parts]


def strip_outer_parens(text):
    text = text.strip()
    if text.startswith('(') and text.endswith(')'):
        depth = 0
        for i, ch in enumerate(text):
            depth += (ch == '(') - (ch == ')')
            if depth == 0 and i < len(text) - 1:
                return text  # the first "(" closes before the end
        return text[1:-1].strip()
    return text


def type_word(word):
    """Matches a type name that could also be a column name, only where a type goes"""
    return r'(?<=[\w"\]`)])(\s+)' + word + r'\b'


def skip_reason(s, dialect, db):
    """Why a (masked) statement can't be converted, or None. '' means skip quietly."""
    head = s.lower()
    if re.match(r'(commit|rollback)\b', head):
        return ''
    if BLOCK.match(s) or re.match(r'(exec|execute|print|delimiter)\b', head):
        return 'procedural code is not converted'
    if re.match(r'(grant|revoke)\b', head) or re.search(r'\bowner\s+to\b', head):
        return 'permissions are for the original database\'s users'
    if re.match(r'(comment\s+on|alter\s+session|set|use|create\s+extension|create\s+schema)\b', head):
        return '%s-only statement' % DB_NAMES[dialect]
    if db == 'mysql':
        uses_sequence = re.sub(r"\bdefault\s+(?:nextval\s*\(\s*\x00\d+\x00\s*\)|\S+\.nextval\b)", '', head)
        if re.match(r'create\s+sequence\b', head) or re.search(r"\.nextval\b|\bnextval\s*\(", uses_sequence):
            return 'MySQL has no sequences'
    return None


def to_oracle_forms(s, dialect):
    """Rewrites PostgreSQL, SQL Server or MySQL syntax into the Oracle forms that
    the conversion to the target database understands"""
    if dialect == 'postgres':
        s = re.sub(r'::\s*[\w ]+(\(\d+(,\s*\d+)?\))?', '', s)  # casts
        s = re.sub(r'\bbigserial\b', 'BIGINT GENERATED BY DEFAULT AS IDENTITY', s, flags=I)
        s = re.sub(r'\b(small)?serial\b', 'INTEGER GENERATED BY DEFAULT AS IDENTITY', s, flags=I)
        s = re.sub(r'\bcharacter\s+varying\b', 'VARCHAR2', s, flags=I)
        s = re.sub(r'\btimestamptz\b', 'TIMESTAMP WITH TIME ZONE', s, flags=I)
        s = re.sub(r'\s+without\s+time\s+zone\b', '', s, flags=I)
        s = re.sub(r'\bint2\b', 'SMALLINT', s, flags=I)
        s = re.sub(r'\bint4\b', 'INTEGER', s, flags=I)
        s = re.sub(r'\bint8\b', 'BIGINT', s, flags=I)
        s = re.sub(r'\bfloat8\b', 'DOUBLE PRECISION', s, flags=I)
        s = re.sub(type_word('bytea'), r'\1BLOB', s, flags=I)
        s = re.sub(type_word('(?:text|jsonb?)'), r'\1CLOB', s, flags=I)
        s = re.sub(type_word('uuid'), r'\1VARCHAR2(36)', s, flags=I)
        s = re.sub(type_word('bool(?:ean)?'), r'\1NUMBER(1)', s, flags=I)
        s = re.sub(r'\btrue\b', '1', s, flags=I)
        s = re.sub(r'\bfalse\b', '0', s, flags=I)
        s = re.sub(r'\b(?:now|transaction_timestamp|clock_timestamp)\s*\(\s*\)', 'SYSTIMESTAMP', s, flags=I)
        s = re.sub(r'\b(?:gen_random_uuid|uuid_generate_v4)\s*\(\s*\)', 'SYS_GUID()', s, flags=I)
        s = re.sub(r"\bnextval\s*\(\s*\x00(\d+)\x00\s*\)", r'NEXTVAL_\1', s, flags=I)  # fixed up by caller
        s = re.sub(r'\bif\s+not\s+exists\s+', '', s, flags=I)
        s = re.sub(r'\s+using\s+(?:btree|hash|gin|gist)\b', '', s, flags=I)
        s = re.sub(r'\s+on\s+conflict\b.*?\bdo\s+nothing\b', '', s, flags=S)
        s = re.sub(r'^(alter\s+table\s+)only\s+', r'\1', s, flags=I)
    elif dialect == 'mssql':
        s = re.sub(r'(?:\[dbo\]|\bdbo)\s*\.\s*', '', s, flags=I)
        s = re.sub(r'\[((?:big|small|tiny)?int|n?varchar|n?char|bit|date|time|datetime2?|smalldatetime|datetimeoffset|'
                   r'uniqueidentifier|decimal|numeric|float|real|money|n?text|image|varbinary|binary|xml|sysname)\]',
                   r'\1', s, flags=I)
        s = re.sub(r'\[([^\]]+)\]', r'"\1"', s)
        s = re.sub(r'\b(?:n?varchar|n?text)\s*\(\s*max\s*\)|' + type_word('n?text'), ' CLOB', s, flags=I)
        s = re.sub(r'\bvarbinary\s*\(\s*max\s*\)|' + type_word('image'), ' BLOB', s, flags=I)
        s = re.sub(r'\bvarbinary\s*\(', 'RAW(', s, flags=I)
        s = re.sub(r'\bdatetimeoffset\b(?:\s*\(\s*\d+\s*\))?', 'TIMESTAMP WITH TIME ZONE', s, flags=I)
        s = re.sub(r'\b(?:datetime2|datetime|smalldatetime)\b(?:\s*\(\s*\d+\s*\))?', 'TIMESTAMP', s, flags=I)
        s = re.sub(type_word('bit'), r'\1NUMBER(1)', s, flags=I)
        s = re.sub(type_word('uniqueidentifier'), r'\1VARCHAR2(36)', s, flags=I)
        s = re.sub(type_word('money'), r'\1NUMBER(19,4)', s, flags=I)
        s = re.sub(type_word('sysname'), r'\1VARCHAR2(128)', s, flags=I)
        s = re.sub(r'\bidentity\s*\(\s*\d+\s*,\s*\d+\s*\)', 'GENERATED BY DEFAULT AS IDENTITY', s, flags=I)
        s = re.sub(r'\b(?:getdate|getutcdate|sysdatetime|sysutcdatetime|sysdatetimeoffset)\s*\(\s*\)', 'SYSTIMESTAMP', s, flags=I)
        s = re.sub(r'\bnewid\s*\(\s*\)', 'SYS_GUID()', s, flags=I)
        s = re.sub(r'\bnext\s+value\s+for\s+' + NAME, r'\1.nextval', s, flags=I)
        s = re.sub(r'\b(?:non)?clustered\b', '', s, flags=I)
        s = re.sub(r'\s+(?:textimage_)?on\s+"?primary"?(?!\s*key)', '', s, flags=I)  # filegroups
        s = re.sub(r'\s+with\s*\(\s*(?:pad_index|statistics_norecompute|ignore_dup_key|allow_row_locks|'
                   r'allow_page_locks|fillfactor|data_compression|optimize_for_sequential_key)[^)]*\)', '', s, flags=I)
    elif dialect == 'mysql':
        s = re.sub(r'`([^`]+)`', r'"\1"', s)
        s = re.sub(r'\btinyint\s*\(\s*1\s*\)', 'NUMBER(1)', s, flags=I)
        s = re.sub(r'\b(tiny|small|big)?int(?:eger)?\s*\(\s*\d+\s*\)', lambda m: (m.group(1) or '') + 'INT', s, flags=I)
        s = re.sub(r'\bmediumint\b', 'INT', s, flags=I)
        s = re.sub(r'\s+unsigned\b|\s+zerofill\b', '', s, flags=I)
        s = re.sub(r'\b(?:tiny|medium|long)?text\b', 'CLOB', s, flags=I)
        s = re.sub(r'\b(?:tiny|medium|long)?blob\b', 'BLOB', s, flags=I)
        s = re.sub(r'\bdatetime\b(?:\s*\(\s*\d+\s*\))?', 'TIMESTAMP', s, flags=I)
        s = re.sub(r'\bdouble\b(?!\s+precision)', 'DOUBLE PRECISION', s, flags=I)
        s = re.sub(r'\benum\s*\([^)]*\)', 'VARCHAR2(255)', s, flags=I)
        s = re.sub(r'\bauto_increment\b(?!\s*=)', 'GENERATED BY DEFAULT AS IDENTITY', s, flags=I)
        s = re.sub(r'\b(?:now|current_timestamp|utc_timestamp)\s*\(\s*\d*\s*\)', 'SYSTIMESTAMP', s, flags=I)
        s = re.sub(r'\buuid\s*\(\s*\)', 'SYS_GUID()', s, flags=I)
        s = re.sub(r'\s+on\s+update\s+\w+(\s*\(\s*\d*\s*\))?', '', s, flags=I)
        s = re.sub(r'\s+comment\s+\x00\d+\x00', '', s, flags=I)
        s = re.sub(r'\b(?:engine|auto_increment|row_format|(?:default\s+)?(?:charset|character\s+set)|collate)\s*=?\s*\w+', '', s, flags=I)
        s = re.sub(r'\bif\s+not\s+exists\s+', '', s, flags=I)
        s = re.sub(r'^insert\s+ignore\b', 'INSERT', s, flags=I)
        s = re.sub(r'(^|,)(\s*)unique\s+key\s+([\w"]+)\s*\(', r'\1\2CONSTRAINT \3 UNIQUE (', s, flags=M)
        s = re.sub(r'(^|,)(\s*)key\s+([\w"]+)\s*\(', r'\1\2INDEX \3 (', s, flags=M)
    return s


# (table, column) pairs that convert_mssql made into computed columns
COMPUTED = set()
# (table, column) -> VARCHAR length, as convert_mysql created them
VARCHARS = {}


def convert(stmt, dialect, db):
    """Converts a statement written for <dialect> to <db>. Returns (sql, note) to
    run it, with an optional note to show, or (None, reason) to skip it; an
    empty reason means skip quietly."""
    s, restore = mask_literals(stmt)
    reason = skip_reason(s, dialect, db)
    if reason is not None:
        return None, reason
    s = to_oracle_forms(s, dialect)
    if dialect == 'postgres':
        # nextval('seq') -> seq.nextval, now that the literal can be read
        s = re.sub(r'NEXTVAL_(\d+)', lambda m: restore('\x00%s\x00' % m.group(1)).strip("'") + '.nextval', s)

    # Character-length semantics, NVL and Oracle storage clauses
    s = re.sub(r'\(\s*(\d+|\*)\s+(?:char|byte)\s*\)', r'(\1)', s, flags=I)
    s = re.sub(r'\bnvl\s*\(', 'COALESCE(', s, flags=I)
    s = re.sub(r'\btablespace\s+[\w$#"]+', '', s, flags=I)
    s = re.sub(r'\bstorage\s*\([^)]*\)', '', s, flags=I)
    s = re.sub(r'\b(?:pctfree|pctused|initrans|maxtrans)\s+\d+', '', s, flags=I)
    s = re.sub(r'\bsegment\s+creation\s+(?:immediate|deferred)\b', '', s, flags=I)
    s = re.sub(r'\b(?:no)?(?:logging|compress)\b|\bcompute\s+statistics\b', '', s, flags=I)
    s = re.sub(r'\s+enable(?=\s*(?:,|\)|$))', '', s, flags=I)
    s = re.sub(r'\s+cascade\s+constraints\b|\s+purge\s*$', '', s, flags=I)
    s = re.sub(r'^(create\s+(?:unique\s+)?index\s+)' + PART + r'\.', r'\1', s, flags=I)
    s = re.sub(r'\bnumber\s*\(\s*\*\s*,', 'number(38,', s, flags=I)

    # Identity columns need an integer type; Oracle's NUMBER(n) becomes BIGINT
    identity = 'IDENTITY(1,1)' if db == 'mssql' else 'AUTO_INCREMENT'
    s = re.sub(r'\b(?:number|numeric|decimal|integer|int|bigint|smallint)\b(\s*\([^)]*\))?(\s+not\s+null)?\s+generated\s+'
               r'(?:always|by\s+default(?:\s+on\s+null)?)\s+as\s+identity\b(\s*\([^)]*\))?',
               lambda m: 'BIGINT ' + identity + (m.group(2) or ''), s, flags=I)

    s, note = convert_mssql(s) if db == 'mssql' else convert_mysql(s)
    return restore(quote_reserved(s.strip(), db)), note


def convert_mssql(s):
    def varchar(m):
        n = int(m.group(1))
        return 'NVARCHAR(MAX)' if n > 4000 else 'NVARCHAR(%d)' % n

    s = re.sub(r'\bn?varchar2?\s*\(\s*(\d+)\s*\)', varchar, s, flags=I)
    s = re.sub(r'\bn?clob\b', 'NVARCHAR(MAX)', s, flags=I)
    s = re.sub(r'\bblob\b', 'VARBINARY(MAX)', s, flags=I)
    s = re.sub(r'\braw\s*\(\s*(\d+)\s*\)', r'VARBINARY(\1)', s, flags=I)
    s = re.sub(r'\bnumber\s*\(', 'NUMERIC(', s, flags=I)
    s = re.sub(r'\bnumber\b', 'NUMERIC(38,10)', s, flags=I)
    s = re.sub(r'\btimestamp\s*(?:\(\s*\d+\s*\))?\s+with\s+(?:local\s+)?time\s+zone\b', 'DATETIMEOFFSET', s, flags=I)
    s = re.sub(r'\btimestamp\b(?:\s*\(\s*\d+\s*\))?', 'DATETIME2', s, flags=I)
    s = re.sub(r"\bdate\b(?!\s*[(\x00])", 'DATETIME2', s, flags=I)
    s = re.sub(r'\brawtohex\s*\(\s*sys_guid\s*\(\s*\)\s*\)', "REPLACE(CONVERT(VARCHAR(36), NEWID()), '-', '')", s, flags=I)
    s = re.sub(r'\bsys_guid\s*\(\s*\)', 'NEWID()', s, flags=I)
    s = re.sub(r'\b(?:systimestamp|sysdate|localtimestamp)\b', 'SYSDATETIME()', s, flags=I)
    s = re.sub(r'\s+from\s+dual\b', '', s, flags=I)
    s = re.sub(NAME + r'\.nextval\b', r'NEXT VALUE FOR \1', s, flags=I)
    s = re.sub(r'\bvirtual\b', '', s, flags=I)
    s = re.sub(r'\bif\s+not\s+exists\s+', '', s, flags=I)
    # Virtual column: "name type GENERATED ALWAYS AS (expr)" -> computed column "name AS (expr)"
    virtual = r'(' + PART + r')\s+[\w$#]+(?:\s*\([^)]*\))?\s+generated\s+always\s+as\s*\('
    table = re.match(r'(?:alter|create)\s+table\s+' + NAME, s, I)
    for m in re.finditer(virtual, s, I):
        if table:
            COMPUTED.add((bare_name(table.group(1)), bare_name(m.group(1))))
    s = re.sub(virtual, r'\1 AS (', s, flags=I)
    s = re.sub(r'^create\s+(?:or\s+replace\s+)?(?:public\s+)?synonym\b', 'CREATE SYNONYM', s, flags=I)
    s = re.sub(r'^create\s+or\s+replace\s+(?:(?:no)?force\s+)?view\b', 'CREATE OR ALTER VIEW', s, flags=I)

    # ALTER TABLE t ADD (a ..., b ...) -> ADD a ..., b ...; ADD COLUMN and MODIFY -> SQL Server's forms
    s = re.sub(r'^(alter\s+table\s+\S+\s+add)\s+column\b', r'\1', s, flags=I)
    m = re.match(r'(alter\s+table\s+\S+\s+add)\s*(\(.*\))\s*$', s, S)
    if m:
        s = m.group(1) + ' ' + strip_outer_parens(m.group(2))
    m = re.match(r'(alter\s+table\s+\S+\s+)modify(?:\s+column)?\s*(.*)$', s, S)
    if m:
        s = m.group(1) + 'ALTER COLUMN ' + strip_outer_parens(m.group(2))

    m = re.match(r'(?:rename|alter\s+table)\s+' + NAME + r'\s+(?:rename\s+)?to\s+' + NAME + r'\s*$', s, I)
    if m:
        s = "EXEC sp_rename '%s', '%s'" % (m.group(1).replace('"', ''), m.group(2).split('.')[-1].strip('"'))

    if re.match(r'create\s+sequence\b', s, I):
        s = re.sub(r'\bno(cache|cycle|maxvalue|minvalue)\b', r'NO \1', s, flags=I)
        s = re.sub(r'\b(?:no)?order\b', '', s, flags=I)
        s = re.sub(r'\bmaxvalue\s+\d{19,}', '', s, flags=I)  # too big for BIGINT
        if not re.search(r'\bstart\s+with\b', s, I):
            s += ' START WITH 1'  # SQL Server would otherwise start at the type's minimum

    note = None
    m = re.match(r'(create\s+(unique\s+)?index\s+\S+\s+on\s+(\S+?)\s*)\((.*)\)\s*$', s, S)
    if m:
        # SQL Server's default collation is case-insensitive, so UPPER()/LOWER() indexes are just column indexes
        cols = [re.sub(r'^(?:upper|lower)\s*\(\s*(' + PART + r')\s*\)', r'\1', c, flags=I) for c in split_top_level(m.group(4))]
        s = m.group(1) + '(' + ', '.join(cols) + ')'
        simple = all(re.fullmatch(PART + r'(?:\s+(?:asc|desc))?', c, I) for c in cols)
        if m.group(2) and simple:
            # Oracle and PostgreSQL unique indexes ignore NULLs; SQL Server allows only one NULL
            # unless the index is filtered, and it can't filter on a computed column
            table = bare_name(m.group(3))
            if any((table, bare_name(c.split()[0])) in COMPUTED for c in cols):
                s = re.sub(r'^create\s+unique\s+', 'CREATE ', s, flags=I)
                note = 'created as a non-unique index: SQL Server can\'t ignore NULLs in a unique index on a computed column'
            else:
                s += ' WHERE ' + ' AND '.join(c.split()[0] + ' IS NOT NULL' for c in cols)
    return s, note


def convert_mysql(s):
    def varchar(m):
        n = int(m.group(1))
        return 'LONGTEXT' if n > 16383 else 'VARCHAR(%d)' % n

    s = re.sub(r'"([^"]+)"', r'`\1`', s)  # MySQL reads double quotes as strings
    s = re.sub(r'\bn?varchar2?\s*\(\s*(\d+)\s*\)', varchar, s, flags=I)
    s = re.sub(r'\bn?clob\b', 'LONGTEXT', s, flags=I)
    s = re.sub(r'\bblob\b', 'LONGBLOB', s, flags=I)
    s = re.sub(r'\braw\s*\(\s*(\d+)\s*\)', r'VARBINARY(\1)', s, flags=I)
    s = re.sub(r'\bnumber\s*\(', 'DECIMAL(', s, flags=I)
    s = re.sub(r'\bnumber\b', 'DECIMAL(38,10)', s, flags=I)
    # DATETIME(6) throughout, so CURRENT_TIMESTAMP(6) defaults match the column's precision
    s = re.sub(r'\btimestamp\s*(?:\(\s*\d+\s*\))?\s+with\s+(?:local\s+)?time\s+zone\b', 'DATETIME(6)', s, flags=I)
    s = re.sub(r'\btimestamp\b(?:\s*\(\s*\d+\s*\))?', 'DATETIME(6)', s, flags=I)
    s = re.sub(r"\bdate\b(?!\s*[(\x00])", 'DATETIME(6)', s, flags=I)
    s = re.sub(r'\brawtohex\s*\(\s*sys_guid\s*\(\s*\)\s*\)', "REPLACE(UUID(), '-', '')", s, flags=I)
    s = re.sub(r'\bsys_guid\s*\(\s*\)', 'UUID()', s, flags=I)
    s = re.sub(r'\b(?:systimestamp|sysdate|localtimestamp)\b', 'CURRENT_TIMESTAMP(6)', s, flags=I)
    s = re.sub(r'\bcurrent_timestamp\b(?!\s*\()', 'CURRENT_TIMESTAMP(6)', s, flags=I)
    note = None
    if re.search(r'\bdefault\s+' + NAME + r'\.nextval\b', s, I):
        s = re.sub(r'\s+default\s+' + NAME + r'\.nextval\b', '', s, flags=I)
        note = 'dropped a sequence default; MySQL has no sequences'
    s = wrap_default_expressions(s)

    m = re.match(r'(alter\s+table\s+\S+\s+modify)(?:\s+column)?\s*(.*)$', s, S)
    if m:
        s = m.group(1) + ' ' + strip_outer_parens(m.group(2))

    m = re.match(r'(?:rename|alter\s+table)\s+' + NAME + r'\s+(?:rename\s+)?to\s+' + NAME + r'\s*$', s, I)
    if m:
        s = 'RENAME TABLE %s TO %s' % (m.group(1), m.group(2))

    # MySQL has no synonyms; a view works for reads and simple writes
    m = re.match(r'create\s+(?:or\s+replace\s+)?(?:public\s+)?synonym\s+' + NAME + r'\s+for\s+' + NAME + r'\s*$', s, I)
    if m:
        s = 'CREATE OR REPLACE VIEW %s AS SELECT * FROM %s' % (m.group(1), m.group(2))
    s = re.sub(r'^create\s+or\s+(?:replace|alter)\s+(?:(?:no)?force\s+)?view\b', 'CREATE OR REPLACE VIEW', s, flags=I)

    table = re.match(r'(?:create|alter)\s+table\s+' + NAME, s, I)
    if table:
        for col, n in re.findall(r'(' + PART + r')\s+VARCHAR\((\d+)\)', s, I):
            VARCHARS[(bare_name(table.group(1)), bare_name(col))] = int(n)

    m = re.match(r'(create\s+(unique\s+)?index\s+\S+\s+on\s+(\S+?)\s*)\((.*)\)\s*$', s, S)
    if m:
        # Function-based index parts need their own parentheses in MySQL
        cols = ['(%s)' % c if '(' in c and not c.startswith('(') else c for c in split_top_level(m.group(4))]
        # A key over 3072 bytes (768 utf8mb4 characters) fails; for a non-unique
        # index, index only the start of the long VARCHAR columns instead
        lengths = [VARCHARS.get((bare_name(m.group(3)), bare_name(c.split()[0])), 0) for c in cols]
        if not m.group(2) and sum(lengths) > 768:
            share = 768 // len(cols)
            cols = [re.sub(r'^(\S+)', r'\1(%d)' % share, c) if n > share else c for c, n in zip(cols, lengths)]
            note = 'indexes the first %d characters of long columns, to fit MySQL\'s key size limit' % share
        s = m.group(1) + '(' + ', '.join(cols) + ')'
    return s, note


def wrap_default_expressions(s):
    """MySQL needs DEFAULT (expression) in parentheses for anything but a constant
    or CURRENT_TIMESTAMP"""
    out, pos = '', 0
    pattern = re.compile(r'\bdefault\s+([a-z_][\w$#]*)\s*\(', I)
    while True:
        m = pattern.search(s, pos)
        if not m:
            return out + s[pos:]
        if m.group(1).lower() in ('current_timestamp', 'now', 'localtime', 'localtimestamp'):
            out, pos = out + s[pos:m.end()], m.end()
            continue
        depth, j = 0, m.end() - 1
        while j < len(s):
            depth += (s[j] == '(') - (s[j] == ')')
            if depth == 0:
                break
            j += 1
        out += s[pos:m.start(1)] + '(' + s[m.start(1):j + 1] + ')'
        pos = j + 1


def quote_reserved(s, db):
    """Quotes reserved words used as column names: the first word of each column
    definition, and names in parenthesized column lists (keys, indexes, INSERT)"""
    words = RESERVED[db]
    quote = '[%s]' if db == 'mssql' else '`%s`'

    def quote_first(item):
        m = re.match(r'(\s*)([\w$#]+)', item)
        if m and m.group(2).lower() in words:
            return m.group(1) + quote % m.group(2) + item[m.end():]
        return item

    m = re.match(r'(create\s+(?:global\s+temporary\s+)?table\s+\S+\s*\()(.*)(\).*)$', s, S)
    if m:
        s = m.group(1) + ',\n    '.join(quote_first(c) for c in split_top_level(m.group(2))) + m.group(3)
    m = re.match(r'(alter\s+table\s+\S+\s+(?:add|modify|alter\s+column)\s*)(.*)$', s, S)
    if m:
        body = m.group(2)
        if body.startswith('(') and strip_outer_parens(body) != body:
            s = m.group(1) + '(' + ', '.join(quote_first(c) for c in split_top_level(strip_outer_parens(body))) + ')'
        else:
            s = m.group(1) + ', '.join(quote_first(c) for c in split_top_level(body))
    return re.sub(r'\(([\s\w$#",]+)\)',
                  lambda l: '(' + ','.join(quote_first(c) for c in l.group(1).split(',')) + ')', s)


# ---------------------------------------------------------------------------
# Running statements

def run_statement(sql, db, database):
    """Runs a statement in the identityiq or plugin database. Returns (succeeded, error message)"""
    env = os.environ
    if db == 'mssql':
        # Each database's own login, whose default schema is where new objects go
        user = env.get('MSSQL_USER', 'identityiq') if database == 'identityiq' else 'identityiqPlugin'
        # -x: don't treat $(...) as a sqlcmd variable; -I: QUOTED_IDENTIFIER ON,
        # which computed-column and filtered indexes need
        cmd = ['sqlcmd', '-S', env.get('MSSQL_HOST', 'db'), '-U', user,
               '-P', env.get('MSSQL_PASS', ''), '-d', database, '-C', '-N', 'o', '-I', '-x', '-b', '-Q', sql]
        child_env = env
    else:
        cmd = ['mysql', '-h', env.get('MYSQL_HOST', 'localhost'), '-u', 'root',
               '--default-character-set=utf8mb4', database, '-e', sql]
        child_env = dict(env, MYSQL_PWD=env.get('MYSQL_ROOT_PASSWORD', ''))
    try:
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                env=child_env, timeout=120, universal_newlines=True)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, str(e)
    if result.returncode == 0:
        return True, ''
    lines = [l.strip() for l in result.stdout.splitlines() if l.strip() and not l.startswith('Msg ')]
    message = lines[-1] if lines else 'exit code %d' % result.returncode
    return False, re.sub(r' at line \d+', '', message)


def summary(sql):
    text = ' '.join(sql.split())
    return text if len(text) <= 100 else text[:97] + '...'


def main():
    parser = argparse.ArgumentParser(description="Runs an SSB db/ folder's scripts against IIQ's database.")
    parser.add_argument('--db', choices=['mssql', 'mysql'], required=True)
    parser.add_argument('--source-url', help="the SSB's original JDBC URL, for .sql files whose syntax doesn't say")
    parser.add_argument('--dry-run', action='store_true', help='print the run order and converted SQL; run nothing')
    parser.add_argument('folder')
    args = parser.parse_args()

    chosen, not_used = find_scripts(args.folder, args.db)
    if not chosen:
        print('=> No SSB database scripts found in %s' % args.folder)
        return 0

    fallback = url_dialect(args.source_url) or 'oracle'
    plugin_db = plugin_database(args.db)
    scripts = {}
    for rel, dialect in chosen:
        with open(os.path.join(args.folder, rel), encoding='utf-8-sig', errors='replace') as f:
            text = f.read()
        dialect = dialect or detect_dialect(text, fallback)
        statements = split_statements(text, dialect)
        creates, uses = set(), set()
        for stmt in statements:
            c, u = object_names(stmt)
            creates |= c
            uses |= u
        database = 'identityiq' if any(changes_iiq_object(s) for s in statements) else plugin_db
        scripts[rel] = (dialect, statements, creates, uses, database)

    order = order_scripts({rel: (v[2], v[3]) for rel, v in scripts.items()})
    print('=> Running SSB database scripts on %s, in this order:' % DB_NAMES[args.db])
    for n, rel in enumerate(order, 1):
        dialect, database = scripts[rel][0], scripts[rel][4]
        print('   %d. %s (%s, in %s)' % (n, rel, 'as-is' if dialect == args.db else 'from ' + DB_NAMES[dialect], database))
    for rel in not_used:
        print('   -  %s (not used: another version of the same script was picked)' % rel)

    totals = {'ran': 0, 'skipped': 0, 'failed': 0}
    for rel in order:
        dialect, statements, _, _, database = scripts[rel]
        print('=> %s (in %s)' % (rel, database))
        counts = {'ran': 0, 'skipped': 0, 'failed': 0}
        for stmt in statements:
            sql, note = (stmt, None) if dialect == args.db else convert(stmt, dialect, args.db)
            if sql is None:
                if note:
                    counts['skipped'] += 1
                    print('   - Skipped (%s): %s' % (note, summary(stmt)))
                continue
            if note:
                print('   ! Note (%s): %s' % (note, summary(stmt)))
            if args.dry_run:
                print(sql + ';\n')
                counts['ran'] += 1
                continue
            ok, error = run_statement(sql, args.db, database)
            if ok:
                counts['ran'] += 1
            else:
                counts['failed'] += 1
                print('   x Failed: %s\n     %s' % (summary(sql), error))
        print('   %d ran, %d skipped, %d failed' % (counts['ran'], counts['skipped'], counts['failed']))
        for k in totals:
            totals[k] += counts[k]

    print('=> SSB database scripts done: %d statements ran, %d skipped, %d failed'
          % (totals['ran'], totals['skipped'], totals['failed']))
    if totals['failed']:
        print('   Failures are expected for changes meant for an older database (renames, added columns);')
        print('   check any others before relying on those tables.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
