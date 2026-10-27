import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

const datasetUrl = 'https://www.data.gouv.fr/api/1/datasets/5af120e5b595087cfabcde81/';
const output = resolve('assets', 'data', 'monuments_ile_de_france.json');
const departments = new Set(['75', '77', '78', '91', '92', '93', '94', '95']);
const userAgent = 'ChauffeurMonumentsCatalog/1.0 (local open-data catalog export)';

async function request(url) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const response = await fetch(url, {
      headers: { 'User-Agent': userAgent },
      signal: AbortSignal.timeout(120000),
    });
    if (response.ok) return response;
    if (![429, 500, 502, 503, 504].includes(response.status) || attempt === 4) {
      throw new Error(`HTTP ${response.status}: ${url}`);
    }
    const retryAfter = response.headers.get('retry-after');
    const seconds = retryAfter === null ? NaN : Number(retryAfter);
    const requestedWait = Number.isFinite(seconds)
      ? seconds * 1000
      : Date.parse(retryAfter ?? '') - Date.now();
    const wait = Math.max(
      30000 * (attempt + 1),
      Number.isFinite(requestedWait) ? requestedWait : 0,
    );
    await response.body?.cancel();
    console.error(`HTTP ${response.status}; retrying in ${Math.ceil(wait / 1000)} seconds.`);
    await delay(wait);
  }
}

function parseCsv(text) {
  const rows = [];
  let row = [];
  let field = '';
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (char === '"') {
      if (quoted && text[i + 1] === '"') {
        field += '"';
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (!quoted && char === '|') {
      row.push(field);
      field = '';
    } else if (!quoted && char === '\n') {
      row.push(field.replace(/\r$/, ''));
      rows.push(row);
      row = [];
      field = '';
    } else {
      field += char;
    }
  }
  if (quoted) throw new Error('Unterminated quoted CSV field.');
  if (row.length || field) {
    row.push(field.replace(/\r$/, ''));
    rows.push(row);
  }
  const headers = rows.shift().map((value) => value.replace(/^\uFEFF/, ''));
  return rows.filter((values) => values.some(Boolean)).map((values) => {
    if (values.length !== headers.length) {
      throw new Error(`CSV column count mismatch: ${values[0]}`);
    }
    return Object.fromEntries(headers.map((key, i) => [key, values[i]]));
  });
}

function value(text) {
  return text?.trim() || null;
}

function position(text) {
  if (!value(text)) return null;
  const parts = text.split(',').map((part) => Number(part.trim()));
  if (parts.length !== 2 || !parts.every(Number.isFinite) ||
      Math.abs(parts[0]) > 90 || Math.abs(parts[1]) > 180) {
    throw new Error(`Invalid WGS84 position: ${text}`);
  }
  return { latitude: parts[0], longitude: parts[1] };
}

async function save(catalog) {
  await mkdir(dirname(output), { recursive: true });
  const temporary = `${output}.tmp`;
  await writeFile(temporary, `${JSON.stringify(catalog, null, 2)}\n`, 'utf8');
  await rename(temporary, output);
}

async function createCatalog() {
  const metadata = await (await request(datasetUrl)).json();
  if (metadata.license !== 'lov2') {
    throw new Error(`Review source license before export: ${metadata.license}`);
  }
  const resource = metadata.resources.find((item) => item.format === 'csv');
  if (!resource) throw new Error('Official CSV resource not found.');
  console.log('Downloading the Ministry of Culture CSV.');
  const records = parseCsv(await (await request(resource.url)).text());
  const monuments = records.filter((row) =>
    departments.has(row.Departement_format_numerique?.trim()),
  ).map((row) => ({
    reference: row.Reference,
    nom: value(row.Titre_editorial_de_la_notice) ??
      value(row.Denomination_de_l_edifice),
    description: value(row.Description_de_l_edifice),
    histoire: value(row.Historique),
    position: position(row.coordonnees_au_format_WGS84),
    adresse: value(row.Adresse_forme_editoriale) ?? value(row.Adresse_forme_index),
    commune: value(row.Commune_forme_editoriale) ?? value(row.Commune_forme_index),
    departement: row.Departement_format_numerique.trim(),
    protection: value(row.Date_et_typologie_de_la_protection),
    source: `https://pop.culture.gouv.fr/notice/merimee/${row.Reference}`,
    copyright_source: value(row.Copyright),
    mise_a_jour_source: value(row.Date_de_la_derniere_mise_a_jour),
    photos: [],
    photos_statut: 'a_rechercher',
  })).sort((a, b) => a.reference.localeCompare(b.reference));
  if (monuments.length < 1000 ||
      new Set(monuments.map((item) => item.reference)).size !== monuments.length) {
    throw new Error('Unexpected monument count or duplicate references.');
  }
  const catalog = {
    genere_le: new Date().toISOString(),
    perimetre: 'Notices officielles des immeubles ayant été ou étant protégés au titre des monuments historiques en Île-de-France ; une notice par référence Mérimée.',
    source: {
      producteur: metadata.organization.name,
      jeu_de_donnees: metadata.page,
      telechargement: resource.url,
      mis_a_jour_le: metadata.last_update,
      licence: 'Licence Ouverte 2.0',
      licence_url: 'https://www.etalab.gouv.fr/licence-ouverte-open-licence/',
    },
    photos_source: 'Wikimedia Commons ; recherche par référence Mérimée, sans substitution par un monument de nom similaire.',
    photos_demandees_par_monument: 3,
    champs_absents: 'null signifie non renseigné dans la source ; photos contient uniquement des images dont la licence est vérifiée.',
    monuments,
  };
  await save(catalog);
  console.log(`Exported ${monuments.length} monument records to ${output}.`);
  return catalog;
}

async function photos(reference) {
  const url = new URL('https://commons.wikimedia.org/w/api.php');
  url.search = new URLSearchParams({
    action: 'query',
    format: 'json',
    generator: 'search',
    gsrsearch: reference,
    gsrnamespace: '6',
    gsrlimit: '3',
    prop: 'imageinfo',
    iiprop: 'url|extmetadata|mime',
    iiurlwidth: '1200',
  });
  const data = await (await request(url)).json();
  if (data.error) throw new Error(`Commons: ${JSON.stringify(data.error)}`);
  const results = [];
  for (const page of Object.values(data.query?.pages ?? {})
    .sort((a, b) => a.index - b.index)) {
    const info = page.imageinfo?.[0];
    const meta = info?.extmetadata;
    if (!info?.mime?.startsWith('image/') ||
        !['image/jpeg', 'image/png', 'image/webp'].includes(info.mime)) continue;
    const license = meta?.LicenseShortName?.value;
    const licenseUrl = meta?.LicenseUrl?.value;
    const author = meta?.Artist?.value;
    if (!license || !author ||
        !/^(CC BY(?:-SA)? [1-4]\.\d|CC0|Public domain)/i.test(license)) continue;
    results.push({
      titre: page.title,
      url: info.url,
      miniature: info.thumburl ?? info.url,
      page_source: info.descriptionurl,
      auteur_html: author,
      credit_html: meta.Credit?.value ?? null,
      licence: license,
      licence_url: licenseUrl ?? null,
      attribution_requise: /^CC BY/i.test(license) ||
        meta.AttributionRequired?.value === 'true',
    });
    if (results.length === 3) break;
  }
  return results;
}

async function main() {
  const resume = process.argv.includes('--resume');
  const catalog = resume
    ? JSON.parse(await readFile(output, 'utf8'))
    : await createCatalog();
  if (process.argv.includes('--catalog-only')) return;
  const pending = catalog.monuments.filter((item) =>
    ['a_rechercher', 'erreur_recherche'].includes(item.photos_statut),
  );
  console.log(`Looking up freely licensed photos for ${pending.length} monuments.`);
  let done = 0;
  let consecutiveErrors = 0;
  for (const monument of pending) {
    try {
      monument.photos = await photos(monument.reference);
      monument.photos_statut = monument.photos.length === 3
        ? 'complet'
        : 'moins_de_3_photos_libres_trouvees';
      delete monument.photos_erreur;
      consecutiveErrors = 0;
    } catch (error) {
      monument.photos_statut = 'erreur_recherche';
      monument.photos_erreur = error.message;
      console.error(`${monument.reference}: ${error.message}`);
      consecutiveErrors++;
      if (consecutiveErrors >= 3) {
        await save(catalog);
        throw new Error('Three consecutive photo lookup errors; progress saved. Resume later.');
      }
    }
    done++;
    if (done % 25 === 0 || done === pending.length) {
      await save(catalog);
      console.log(`${done}/${pending.length} photo lookups saved.`);
    }
    await delay(5000);
  }
  console.log(JSON.stringify({
    monuments: catalog.monuments.length,
    avec_3_photos: catalog.monuments.filter((item) => item.photos.length === 3).length,
    erreurs: catalog.monuments.filter((item) => item.photos_statut === 'erreur_recherche').length,
  }));
}

await main();
