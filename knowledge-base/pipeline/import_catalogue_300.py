"""Resumable, build-time Wikimedia catalogue import; no runtime requests or care synthesis.

Snapshots + SHA256 support offline rebuilds. Text is CC BY-SA 4.0 with article/history
attribution; photographs are accepted individually through an explicit license filter.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import html
import json
from pathlib import Path
import re
import sqlite3
import time
import unicodedata
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, quote, urlparse
from urllib.request import Request, urlopen

from catalogue_image import parse_image_dimensions_and_mime
from import_wikidata import values
from rights import require_operations

ROOT = Path(__file__).resolve().parents[2]
RAW = ROOT / 'knowledge-base/raw/catalogue-300'
OUT = ROOT / 'catalogue/releases/skeleton-300-v1'
PLANTFOLIO_DIR = ROOT / 'knowledge-base/references/personal/watering/plantfolio-common-plants'
SPECIES_RANK = 'Q7432'
LICENSE_URL = 'https://creativecommons.org/licenses/by-sa/4.0/'
GENERIC_EN_NAMES = {'cactus', 'orchid', 'plant', 'houseplant', 'tree', 'shrub', 'fern', 'palm', 'succulent'}
POLISH_SOURCE_COLLISIONS = {
    'Q814368': 'begonia koralowa',
    'Q162311': 'hoja piękna',
}
POLISH_NAME_COLLISIONS = {
    'Q31318': {'dracena sandera', 'dracaena sanderiana'},
    'Q814368': {'begonia koralowa'},
    'Q162311': {'hoja piękna', 'hoya bella'},
    'Q883685': {'wilczomlecz okazały'},
}

BROAD_CATEGORY_IDS = {
    'aroids', 'trailing-aroids', 'prayer-plants', 'ferns', 'palms',
    'succulents', 'cacti', 'orchids', 'bromeliads', 'carnivorous-plant',
    'epiphytes', 'indoor-aquatics', 'aquatic-plants', 'bog-plants', 'evergreen-trees',
}

ENGLISH_EXAMPLE_WORDS = {
    'plant', 'plants', 'in', 'water', 'tree', 'trees', 'fern', 'ferns',
    'palm', 'palms', 'moss', 'lily', 'lilies', 'ivy', 'cactus', 'cacti',
    'succulent', 'succulents', 'orchid', 'orchids', 'bamboo', 'grass',
    'herb', 'herbs', 'hybrid', 'hybrids', 'spp', 'var', 'subsp', 'various',
    'colors', 'cultivars', 'single', 'double', 'regular', 'dwarf', 'white',
    'purple', 'orange', 'green', 'red', 'yellow', 'blue', 'pink', 'black',
}

GENUS_GROUP_REPRESENTATIVE = {
    'adenium': 'adenium',
    'adiantum': 'maidenhair-ferns',
    'aeonium': 'aeonium',
    'aeschynanthus': 'lipstick-plant',
    'agave': 'agave',
    'aglaonema': 'aglaonema',
    'alocasia': 'alocasias',
    'aloe': 'aloes',
    'anthurium': 'anthuriums',
    'aporocactus': 'rat-tail-cactus',
    'asparagus': 'asparagus-setaceus',
    'asplenium': 'birds-nest-fern',
    'astrophytum': 'star-cactus',
    'begonia': 'begonia-rex',
    'blechnum': 'blechnum',
    'caladium': 'caladium',
    'calathea': 'prayer-plants',
    'campanula': 'campanula-alpine',
    'carnegiea': 'saguaro',
    'cattleya': 'orchids',
    'ceropegia': 'string-of-hearts',
    'chamaedorea': 'parlor-palm',
    'chamaerops': 'european-fan-palm',
    'chlorophytum': 'spider-plants',
    'cissus': 'grape-ivy',
    'citrus': 'calamondin',
    'clivia': 'clivia',
    'colocasia': 'colocasia',
    'cordyline': 'cordyline',
    'cotyledon': 'bears-paw',
    'crassula': 'crassulas',
    'ctenanthe': 'ctenanthe',
    'cupressus': 'lemon-cypress',
    'curio': 'senecio',
    'cycas': 'cycas-revoluta',
    'cyclamen': 'cyclamen',
    'cymbidium': 'cymbidium',
    'darlingtonia': 'cobra-lily',
    'davallia': 'rabbits-foot-fern',
    'delosperma': 'ice-plant',
    'dendrobium': 'dendrobium-orchid',
    'dieffenbachia': 'dieffenbachia',
    'dischidia': 'dischidia',
    'disocactus': 'rat-tail-cactus',
    'drosera': 'sundew',
    'dypsis': 'areca-palm',
    'echeveria': 'echeveria',
    'echinocactus': 'barrel-cactus',
    'echinopsis': 'echinopsis',
    'epiphyllum': 'epiphyllum',
    'euphorbia': 'euphorbias',
    'ferocactus': 'barrel-cactus',
    'ficus': 'ficus-benjamina',
    'fittonia': 'nerve-plant',
    'geogenanthus': 'geogenanthus',
    'gerbera': 'gerbera-daisy',
    'goeppertia': 'prayer-plants',
    'graptopetalum': 'graptopetalum',
    'guzmania': 'bromeliad-guzmania',
    'gymnocalycium': 'gymnocalycium',
    'gynura': 'purple-passion-plant',
    'haworthia': 'haworthia',
    'haworthiopsis': 'haworthia',
    'heliconia': 'heliconia',
    'heptapleurum': 'schefflera',
    'hippeastrum': 'amaryllis',
    'hoya': 'hoyas',
    'ixora': 'ixora',
    'jasminum': 'jasmine',
    'kalanchoe': 'kalanchoe',
    'lithops': 'lithops',
    'mammillaria': 'mammillaria',
    'mandevilla': 'mandevilla',
    'maranta': 'maranta-prayer-plant',
    'medinilla': 'medinilla',
    'microsorum': 'microsorum-diversifolium',
    'monstera': 'swiss-cheese-plant',
    'murraya': 'curry-leaf',
    'nepenthes': 'nepenthes',
    'nephrolepis': 'boston-ferns',
    'oncidium': 'oncidium-orchid',
    'opuntia': 'opuntia-microdasys',
    'othonna': 'string-of-rubies',
    'oxalis': 'oxalis',
    'pachira': 'money-tree',
    'paphiopedilum': 'paphiopedilum',
    'parodia': 'parodia',
    'pelargonium': 'geraniums',
    'peperomia': 'peperomia',
    'phalaenopsis': 'phalaenopsis-orchids',
    'philodendron': 'philodendron-congo',
    'pilea': 'pilea',
    'pinguicula': 'butterwort',
    'platycerium': 'staghorn-fern',
    'plectranthus': 'swedish-ivy',
    'plerandra': 'false-aralia',
    'podocarpus': 'podocarpus',
    'polyscias': 'aralia-ming',
    'pteris': 'pteris',
    'ravenea': 'majesty-palm',
    'rhaphidophora': 'rhaphidophora-tetrasperma',
    'rhapis': 'lady-palm',
    'rhipsalis': 'rhipsalis',
    'rhododendron': 'azaleas',
    'sansevieria': 'snake-plants',
    'sarracenia': 'sarracenia',
    'schlumbergera': 'christmas-cactus',
    'sedum': 'sedum',
    'selenicereus': 'dragon-fruit',
    'sempervivum': 'sempervivum',
    'senecio': 'senecio',
    'sinningia': 'gloxinia',
    'spathiphyllum': 'peace-lilies',
    'streptocarpus': 'streptocarpus',
    'syngonium': 'arrowhead-plant',
    'thaumatophyllum': 'philodendron-selloum',
    'tillandsia': 'air-plants',
    'vanda': 'vanda-orchid',
    'welwitschia': 'welwitschia',
    'xanthosoma': 'xanthosoma',
    'yucca': 'yucca',
}

BOTANICAL_GROUP_FALLBACK = {
    'achimenes': ('gloxinia', 'Gesneriaceae (Rhizomatous Gesneriads)'),
    'adelonema': ('aroids', 'Araceae (Aroids)'),
    'adromischus': ('crassulas', 'Crassulaceae (Adromischus / Crassula succulent group)'),
    'albuca': ('amaryllis', 'Asparagaceae / Scilloideae (Bulbous ornamentals)'),
    'aloinopsis': ('lithops', 'Aizoaceae (Mesembs / Living stones group)'),
    'alternanthera': ('polka-dot-plant', 'Amaranthaceae (Tropical colorful foliage subshrubs)'),
    'angraecum': ('orchids', 'Orchidaceae (Epiphytic Orchids)'),
    'apocissus': ('grape-ivy', 'Vitaceae (Cissus / Grape Ivy group)'),
    'ardisia': ('gardenia', 'Primulaceae (Indoor berry/evergreen shrub group)'),
    'areca': ('palms', 'Arecaceae (Indoor Palms)'),
    'austrocylindropuntia': ('opuntia-microdasys', 'Cactaceae / Opuntioideae (Opuntioid cacti)'),
    'aylostera': ('parodia', 'Cactaceae (Globular South American cacti)'),
    'billbergia': ('bromeliads', 'Bromeliaceae (Bromeliads)'),
    'brassia': ('oncidium-orchid', 'Orchidaceae / Oncidiinae (Epiphytic Orchids)'),
    'brunfelsia': ('gardenia', 'Solanaceae (Tropical evergreen flowering shrub group)'),
    'callianthe': ('hibiscus-tropical', 'Malvaceae (Abutilon / Callianthe flowering shrub group)'),
    'callisia': ('tradescantia', 'Commelinaceae (Tradescantia / Callisia trailing group)'),
    'campyloneurum': ('ferns', 'Polypodiaceae (Indoor Ferns)'),
    'caryota': ('palms', 'Arecaceae (Indoor Palms)'),
    'cephalocereus': ('cacti', 'Cactaceae (Columnar cacti)'),
    'cereus': ('cacti', 'Cactaceae (Columnar cacti)'),
    'cleistocactus': ('cacti', 'Cactaceae (Columnar cacti)'),
    'clusia': ('rubber-plant', 'Clusiaceae (Thick-leaved tropical shrub/tree group)'),
    'conophytum': ('lithops', 'Aizoaceae (Mesembs / Living stones group)'),
    'crossandra': ('zebra-plant-aphelandra', 'Acanthaceae (Flowering Acanthaceae)'),
    'cryptanthus': ('bromeliads', 'Bromeliaceae (Bromeliads)'),
    'curcuma': ('turmeric', 'Zingiberaceae (Curcuma / Turmeric genus)'),
    'cyanotis': ('tradescantia', 'Commelinaceae (Tradescantia / Cyanotis trailing group)'),
    'cyrtanthus': ('amaryllis', 'Amaryllidaceae (Bulbous Amaryllidaceae)'),
    'cyrtomium': ('ferns', 'Dryopteridaceae (Indoor Ferns)'),
    'didymochlaena': ('ferns', 'Didymochlaenaceae (Indoor Ferns)'),
    'dioscorea': ('adenium', 'Dioscoreaceae (Caudiciform / Succulent group)'),
    'drimiopsis': ('amaryllis', 'Asparagaceae / Scilloideae (Bulbous ornamentals)'),
    'drymonia': ('streptocarpus', 'Gesneriaceae (Gesneriads)'),
    'episcia': ('african-violets', 'Gesneriaceae (Stoloniferous Gesneriads)'),
    'espostoa': ('cacti', 'Cactaceae (Columnar cacti)'),
    'eucomis': ('amaryllis', 'Asparagaceae / Scilloideae (Bulbous ornamentals)'),
    'excoecaria': ('croton', 'Euphorbiaceae (Tropical foliage Euphorbiaceae)'),
    'faucaria': ('lithops', 'Aizoaceae (Mesembs / Tiger jaws group)'),
    'fenestraria': ('lithops', 'Aizoaceae (Mesembs / Window plants group)'),
    'frithia': ('lithops', 'Aizoaceae (Mesembs / Window plants group)'),
    'gomesa': ('oncidium-orchid', 'Orchidaceae / Oncidiinae (Oncidium alliance)'),
    'gonialoe': ('aloes', 'Asphodelaceae (Alooid rosettes)'),
    'haemanthus': ('amaryllis', 'Amaryllidaceae (Bulbous Amaryllidaceae)'),
    'hemigraphis': ('nerve-plant', 'Acanthaceae (Moisture-loving tropical foliage Acanthaceae)'),
    'homalomena': ('aroids', 'Araceae (Aroids)'),
    'huernia': ('succulents', 'Apocynaceae / Stapeliinae (Stem Succulents)'),
    'iresine': ('polka-dot-plant', 'Amaranthaceae (Tropical colorful foliage subshrubs)'),
    'jatropha': ('adenium', 'Euphorbiaceae (Caudiciform / Succulent group)'),
    'justicia': ('zebra-plant-aphelandra', 'Acanthaceae (Flowering Acanthaceae)'),
    'ledebouria': ('amaryllis', 'Asparagaceae / Scilloideae (Bulbous ornamentals)'),
    'lepismium': ('rhipsalis', 'Cactaceae / Rhipsalideae (Epiphytic forest cacti)'),
    'ludisia': ('orchids', 'Orchidaceae (Jewel orchids / Terrestrial orchids)'),
    'magnolia': ('gardenia', 'Magnoliaceae (Indoor evergreen flowering shrub group)'),
    'miltoniopsis': ('oncidium-orchid', 'Orchidaceae / Oncidiinae (Pansy orchids)'),
    'mimosa': ('nerve-plant', 'Fabaceae (Moisture-loving tropical subshrub)'),
    'orbea': ('succulents', 'Apocynaceae / Stapeliinae (Stem Succulents)'),
    'ornithogalum': ('amaryllis', 'Asparagaceae / Scilloideae (Bulbous ornamentals)'),
    'pachypodium': ('adenium', 'Apocynaceae (Caudiciform / Succulent group)'),
    'petrocosmea': ('african-violets', 'Gesneriaceae (Rosette Gesneriads)'),
    'radermachera': ('aralia-ming', 'Bignoniaceae (Indoor compound-leaved tree/shrub group)'),
    'rebutia': ('parodia', 'Cactaceae (Globular South American cacti)'),
    'rhipsalidopsis': ('easter-cactus', 'Cactaceae / Rhipsalideae (Epiphytic holiday cacti)'),
    'ruellia': ('zebra-plant-aphelandra', 'Acanthaceae (Tropical Acanthaceae)'),
    'russelia': ('zebra-plant-aphelandra', 'Plantaginaceae (Tropical flowering subshrub group)'),
    'saribus': ('palms', 'Arecaceae (Indoor Fan Palms)'),
    'scadoxus': ('amaryllis', 'Amaryllidaceae (Bulbous Amaryllidaceae)'),
    'selaginella': ('ferns', 'Selaginellaceae (Spike mosses / Fern allies)'),
    'solanum': ('hibiscus-tropical', 'Solanaceae (Ornamental fruiting/flowering indoor shrub)'),
    'sparrmannia': ('hibiscus-tropical', 'Malvaceae (Indoor Malvaceae shrub/tree group)'),
    'stapelia': ('succulents', 'Apocynaceae / Stapeliinae (Stem Succulents)'),
    'stenocactus': ('cacti', 'Cactaceae (Globular cacti)'),
    'strobilanthes': ('nerve-plant', 'Acanthaceae (Moisture-loving tropical foliage Acanthaceae)'),
    'tabernaemontana': ('gardenia', 'Apocynaceae (Tropical evergreen flowering shrub group)'),
    'titanopsis': ('lithops', 'Aizoaceae (Mesembs / Living stones group)'),
    'tolmiea': ('fatsia', 'Saxifragaceae (Temperate foliage houseplant group)'),
    'turbinicarpus': ('cacti', 'Cactaceae (Globular cacti)'),
    'vriesea': ('bromeliads', 'Bromeliaceae (Bromeliads)'),
    'wallisia': ('air-plants', 'Bromeliaceae / Tillandsioideae (Tillandsia / Wallisia group)'),
    'zealandia': ('microsorum-diversifolium', 'Polypodiaceae (Kangaroo paw fern / Microsorum group)'),
    'zephyranthes': ('amaryllis', 'Amaryllidaceae (Rain lilies / Bulbous Amaryllidaceae)'),
    'zygopetalum': ('orchids', 'Orchidaceae (Epiphytic Orchids)'),
}

WIKIDATA_P225_CORRECTIONS = {
    'Q137455': 'Heptapleurum arboricola',
    'Q15314417': 'Alocasia micholitziana',
}


def dump(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    temp.replace(path)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def clean(value):
    return re.sub(r'\s+', ' ', html.unescape(re.sub('<[^>]+>', '', value or ''))).strip()


def norm(value):
    return unicodedata.normalize('NFKC', value).casefold().strip()


def chunks(items, size):
    for index in range(0, len(items), size):
        yield items[index:index + size]


class Client:
    def __init__(self, agent=None, offline=False):
        self.agent = agent
        self.offline = offline
        self.last_request = 0
        if not offline and (not agent or not re.search(r'mailto:|https://', agent)):
            raise ValueError('A real operator contact in --user-agent is required')

    def request(self, url, target, *, binary=False):
        meta_path = target.with_suffix(target.suffix + '.meta.json')
        if target.exists():
            raw = target.read_bytes()
            meta = json.loads(meta_path.read_text())
            if meta['sha256'] != sha(raw) or meta['url'] != url:
                raise ValueError(f'Cache integrity mismatch: {target}')
            return raw, meta
        if self.offline:
            raise ValueError(f'Missing offline snapshot: {target}')
        if urlparse(url).scheme != 'https' or urlparse(url).hostname not in {
            'en.wikipedia.org', 'pl.wikipedia.org', 'www.wikidata.org',
            'commons.wikimedia.org', 'upload.wikimedia.org', 'thumb.wikimedia.org',
        }:
            raise ValueError('Unexpected source host')
        time.sleep(max(0, 0.6 - (time.monotonic() - self.last_request)))
        for attempt in range(3):
            try:
                with urlopen(Request(url, headers={'User-Agent': self.agent,
                             'Accept': '*/*' if binary else 'application/json'}), timeout=60) as response:
                    raw = response.read(25_000_001)
                if len(raw) > 25_000_000:
                    raise ValueError('Response exceeds size limit')
                if not binary:
                    doc = json.loads(raw)
                    if 'error' in doc:
                        raise ValueError(f'API error: {doc["error"]}')
                self.last_request = time.monotonic()
                break
            except HTTPError as error:
                # Stop on access restrictions; do not retry 403 or rate-limit responses.
                if error.code not in (500, 502, 503, 504) or attempt == 2:
                    raise
                time.sleep(2 ** (attempt + 1))
            except (URLError, TimeoutError):
                if attempt == 2:
                    raise
                time.sleep(2 ** (attempt + 1))
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw)
        meta = {'url': url, 'sha256': sha(raw), 'retrieved_at': datetime.now(timezone.utc).isoformat()}
        dump(meta_path, meta)
        return raw, meta

    def api(self, host, **params):
        params = {'format': 'json', 'formatversion': 2, 'maxlag': 5, **params}
        url = f'https://{host}/w/api.php?' + urlencode(sorted(params.items()))
        path = RAW / 'api' / (sha(url.encode()) + '.json')
        raw, meta = self.request(url, path)
        return json.loads(raw), {**meta, 'snapshot': str(path.relative_to(ROOT))}


def discover(client):
    titles = []
    continuation = {}
    while True:
        doc, meta = client.api('en.wikipedia.org', action='query', list='categorymembers',
            cmtitle='Category:House plants', cmlimit=500, cmtype='page', **continuation)
        titles.extend(p['title'] for p in doc['query']['categorymembers'] if p['ns'] == 0)
        continuation = doc.get('continue')
        if not continuation:
            break
    manual = [s.strip() for s in (ROOT / 'knowledge-base/manifests/catalogue-300-candidates.txt').read_text().splitlines()
              if s.strip() and not s.startswith('#')]
    # Ensure recognisable main groups are represented before the long-tail category.
    priority = manual[:55] + [
        'Hoya carnosa', 'Hoya kerrii', 'Ceropegia woodii', 'Curio rowleyanus',
        'Aloe vera', 'Crassula ovata', 'Kalanchoe blossfeldiana', 'Echeveria elegans',
        'Haworthiopsis attenuata', 'Schlumbergera truncata', 'Rhipsalidopsis gaertneri',
        'Beaucarnea recurvata', 'Yucca gigantea', 'Pachira aquatica',
        'Chrysalidocarpus lutescens', 'Howea forsteriana', 'Cycas revoluta',
        'Araucaria heterophylla', 'Hedera helix', 'Asparagus setaceus', 'Phlebodium aureum',
        'Clivia miniata', 'Hippeastrum striatum', 'Gardenia jasminoides',
        'Jasminum polyanthum', 'Hibiscus rosa-sinensis', 'Coffea arabica',
        'Dionaea muscipula', 'Drosera capensis', 'Nepenthes alata',
        'Phalaenopsis amabilis', 'Phalaenopsis equestris', 'Dendrobium nobile',
        'Cattleya labiata', 'Ludisia discolor', 'Macodes petola',
        'Tillandsia ionantha', 'Tillandsia xerographica', 'Neoregelia carolinae',
        'Cryptanthus bivittatus', 'Billbergia nutans', 'Ananas comosus',
    ]
    result = list(dict.fromkeys(priority + titles + manual))
    dump(OUT / 'discovery.json', {'category_source': meta, 'candidate_count': len(result),
        'selection': 'Editorial priorities, then House plants category, then additional cultivated potted candidates; not a popularity ranking.',
        'titles': result})
    return result


def articles(client, language, titles):
    pages = {}
    for batch in chunks(list(dict.fromkeys(titles)), 20):
        continuation = {}
        # TextExtracts continuation can return only some extracts on the first response.
        while True:
            doc, meta = client.api(f'{language}.wikipedia.org', action='query', titles='|'.join(batch), redirects=1,
                prop='pageprops|extracts|revisions|pageimages|info', ppprop='wikibase_item|disambiguation',
                exintro=1, explaintext=1, exlimit=20, rvprop='ids|timestamp', piprop='name', inprop='url', **continuation)
            for page in doc.get('query', {}).get('pages', []):
                if page.get('missing') or 'disambiguation' in page.get('pageprops', {}):
                    continue
                existing = pages.get(page['title'], {})
                existing.update(page)
                existing.setdefault('snapshots', []).append(meta)
                pages[page['title']] = existing
            continuation = doc.get('continue')
            if not continuation:
                break
        print(f'{language} articles {min(len(pages), len(titles))}/{len(titles)}', flush=True)
    return pages


def entities(client, qids):
    result = {}
    for batch in chunks(list(dict.fromkeys(qids)), 40):
        doc, meta = client.api('www.wikidata.org', action='wbgetentities', ids='|'.join(batch),
            props='info|labels|aliases|descriptions|claims|sitelinks', languages='en|pl', sitefilter='enwiki|plwiki')
        for qid, item in doc['entities'].items():
            item['_snapshot'] = meta
            result[qid] = item
        print(f'entities {len(result)}/{len(qids)}', flush=True)
    return result


def taxon(item):
    names = list(dict.fromkeys(values(item, 'P225')))
    ranks = list(dict.fromkeys(v.get('id') for v in values(item, 'P105') if isinstance(v, dict)))
    if len(names) != 1 or ranks != [SPECIES_RANK]:
        return None
    if not re.fullmatch(r'[A-Z][a-z]+ [a-z][a-z-]+', names[0]):
        return None
    return names[0]


def polish_name_is_eligible(value, qid):
    key = norm(value)
    return not key.startswith('lista gatunków ') and key not in POLISH_NAME_COLLISIONS.get(qid, ())


def eligible_polish_article(item, page):
    if not page or page.get('pageprops', {}).get('wikibase_item') != item['id']:
        return None
    title = norm(page.get('title', ''))
    if not title or title.startswith('lista ') or title == POLISH_SOURCE_COLLISIONS.get(item['id']):
        return None
    return page


def common_names(item, scientific, scientific_genera=()):
    scientific_values = {norm(scientific), *(norm(v) for v in values(item, 'P225'))}
    genus = norm(scientific.split()[0])
    result = {lang: [] for lang in ('en', 'pl')}
    for lang in result:
        candidates = [(v['text'], 'P1843') for v in values(item, 'P1843')
                      if isinstance(v, dict) and v.get('language') == lang]
        label = item.get('labels', {}).get(lang, {}).get('value')
        if label:
            candidates.append((label, 'label'))
        seen = set()
        for value, origin in candidates:
            # Do not pass scientific names / Latin aliases off as common names.
            key = norm(value)
            if not key or key in scientific_values or key == genus or key in scientific_genera:
                continue
            if lang == 'en' and key in GENERIC_EN_NAMES:
                continue
            if lang == 'pl' and not polish_name_is_eligible(value, item['id']):
                continue
            if key not in seen:
                result[lang].append({'name': value, 'source_property': origin, 'source_entity': item['id']})
                seen.add(key)
    return result


def intro_common_names(page, aliases, scientific_genera):
    """Extract explicitly named common names; retain evidence and mark editorial review."""
    text = clean(page.get('extract', ''))
    lead = text[:1800]
    # Only the introductory naming clause can name the plant. Later sentences may
    # name leaf parts, chemicals, other taxa or countries.
    subject = re.split(r'\bis\s+(?:a|an|the|one)\b', lead[:450], maxsplit=1, flags=re.I)[0]
    subject = re.split(r',\s+(?:a|an|in the family)\s+', subject, maxsplit=1, flags=re.I)[0] + '.'
    subject = re.sub(r'\b(?:formerly|previously)\s+known as\s+[^,]+?(?=,\s| and commonly|\.$)', '', subject, flags=re.I)
    clauses = []
    patterns = [
        r"\b(?:commonly |also |sometimes |often )?(?:known as|called)\s+(.+?)(?=,?\s+(?:is|are)\b|[();.])",
        r"\bcommon names?:\s*([^)]{2,240})\)",
        r"^[^.]{0,200}?,\s+the\s+(.+?)(?:,\s*)?\.$",
        r'\bcommonly marketed as\s+["“]([^"”]+)["”]',
    ]
    for pattern in patterns:
        for match in re.finditer(pattern, subject, re.I):
            clauses.append((match.group(1), match.group(0)))
    for match in re.finditer(r'\bCommon names include\s+(.+?)\.', lead):
        clauses.append((match.group(1), match.group(0)))
    for alias in aliases:
        ordinary = re.search(r"\b(?:plant|tree|pothos|fern|palm|fig|ivy|flower|lily|bamboo|cactus|orchid|pepper|sedge|rubber|arrowroot|grass|shamrock|vine|bush|chain|stonecrop|heart|hoya)\b", alias, re.I)
        if len(alias) > 3 and ordinary and re.search(r'(?<!\w)' + re.escape(alias) + r'(?!\w)', lead, re.I):
            clauses.append((alias, alias))
    result = []
    seen = set()
    for clause, evidence in clauses:
        clause = re.split(r'\b(?:due to|among|amongst|hence|like|such as)\b', clause, maxsplit=1, flags=re.I)[0]
        clause = clause.replace('hen and chicken fern', 'hen_AND_chicken fern').replace('hens and chicks', 'hens_AND_chicks')
        for value in re.split(r',|\s+or\s+|\s+and\s+', clause):
            value = value.replace('_AND_', ' and ')
            value = re.sub(r'^(?:as well as|also sold as|and|simply|by its māori name of)\s+', '', value.strip(), flags=re.I)
            value = re.sub(r'\s+and$', '', value, flags=re.I)
            value = re.sub(r'^(?:the|a|an)\s+', '', value.strip(), flags=re.I).strip(" \"'‘’“”.,:")
            if not 3 <= len(value) <= 65 or len(value.split()) > 8 or any(c in value for c in '()[]=0123456789'):
                continue
            if re.search(r'\b(?:species|family|genus|synonym|cultivar|native|because|which|where|when|from|sometimes|commonly|known|called|has|have|in|is|are|that|group|among|amongst|due|hence|like)\b', value, re.I):
                continue
            key = norm(value)
            if any(quote in value for quote in '"“”') or key in GENERIC_EN_NAMES or 'cousin to' in key or 'māori name' in key:
                continue
            if value.split()[0].casefold() in scientific_genera:
                continue
            if key not in seen:
                result.append({'name': value, 'source_property': 'wikipedia_intro',
                    'evidence': evidence, 'source_page_title': page['title'],
                    'source_revision': page.get('revisions', [{}])[0].get('revid'),
                    'review_status': 'extracted_editorial_review_pending'})
                seen.add(key)
    return result


def description(page, language):
    if not page or not clean(page.get('extract')):
        return None
    # Intro only; complete first paragraphs, not a fabricated care profile.
    paragraphs = [p.strip() for p in page['extract'].split('\n') if p.strip()]
    text = '\n\n'.join(paragraphs)
    url = page.get('fullurl') or f'https://{language}.wikipedia.org/wiki/' + quote(page['title'].replace(' ', '_'))
    revision = page.get('revisions', [{}])[0].get('revid')
    return {'text': text, 'language': language, 'source_url': url,
        'source_revision': revision, 'article_wikidata_id': page.get('pageprops', {}).get('wikibase_item'), 'revision_url': f'https://{language}.wikipedia.org/w/index.php?oldid={revision}',
        'history_url': url + '?action=history', 'attribution': f'Wikipedia contributors, {page["title"]}',
        'license': 'CC-BY-SA-4.0', 'license_url': LICENSE_URL,
        'modifications': 'Plain-text introductory section extracted by the Wikimedia API; not translated.',
        'review_status': 'imported_intro_editorial_review_pending', 'snapshots': page['snapshots']}


def translated_description(page, pl_entry):
    if not page or not pl_entry or not clean(pl_entry.get('pl_text')):
        return None
    revision = page.get('revisions', [{}])[0].get('revid')
    if pl_entry.get('source_revision') != revision:
        return None
    paragraphs = [p.strip() for p in pl_entry['pl_text'].split('\n') if p.strip()]
    text = '\n\n'.join(paragraphs)
    url = page.get('fullurl') or 'https://en.wikipedia.org/wiki/' + quote(page['title'].replace(' ', '_'))
    return {
        'text': text,
        'language': 'pl',
        'source_url': url,
        'source_revision': revision,
        'article_wikidata_id': page.get('pageprops', {}).get('wikibase_item'),
        'revision_url': f'https://en.wikipedia.org/w/index.php?oldid={revision}',
        'history_url': url + '?action=history',
        'attribution': f'Wikipedia contributors, {page["title"]} (Polish translation)',
        'license': 'CC-BY-SA-4.0',
        'license_url': LICENSE_URL,
        'modifications': 'Translated into Polish from the English Wikipedia introductory section under CC BY-SA 4.0.',
        'translation_source_language': 'en',
        'review_status': 'translated_intro_editorial_review_pending',
        'snapshots': page['snapshots'],
    }


def translated_pl_common_names(page, pl_entry, item, scientific_name, existing_pl_names, scientific_genera=()):
    if not page or not pl_entry or not pl_entry.get('pl_common_names'):
        return []
    en_rev = page.get('revisions', [{}])[0].get('revid')
    if en_rev is None or pl_entry.get('source_revision') != en_rev:
        return []
    scientific_values = {norm(scientific_name), *(norm(v) for v in values(item, 'P225') if isinstance(v, str))}
    existing_pl = {norm(n['name']) for n in existing_pl_names}
    added = []
    for pl_cname in pl_entry['pl_common_names']:
        val = pl_cname.strip() if isinstance(pl_cname, str) else ''
        if not val or norm(val) in scientific_values or norm(val) in existing_pl or not polish_name_is_eligible(val, item['id']):
            continue
        if val.split()[0].casefold() in scientific_genera:
            continue
        added.append({
            'name': val,
            'source_property': 'wikipedia_intro_pl_translation',
            'source_page_title': page['title'],
            'source_revision': en_rev,
            'review_status': 'translated_editorial_review_pending',
        })
        existing_pl.add(norm(val))
    return added


def permitted_image(page, reviewed_author=None):
    info = (page.get('imageinfo') or [{}])[0]
    ext = info.get('extmetadata', {})
    license_name = clean(ext.get('LicenseShortName', {}).get('value'))
    license_url = clean(ext.get('LicenseUrl', {}).get('value'))
    if license_url.startswith('//'):
        license_url = 'https:' + license_url
    artist = clean(ext.get('Artist', {}).get('value') or ext.get('Attribution', {}).get('value') or reviewed_author)
    credit = clean(ext.get('Credit', {}).get('value'))
    allowed = bool(re.fullmatch(r'CC BY(?:-SA)? (?:1\.0|2\.0|2\.5|3\.0|4\.0)', license_name))
    if license_name in ('CC0', 'Public domain'):
        allowed = True
        license_url = license_url or ('https://creativecommons.org/publicdomain/zero/1.0/' if license_name == 'CC0' else 'https://creativecommons.org/publicdomain/mark/1.0/')
    if not allowed or not artist or not license_url or clean(ext.get('Restrictions', {}).get('value')):
        return None
    if info.get('mime') not in ('image/jpeg', 'image/png', 'image/webp'):
        return None
    source_url = info.get('thumburl') or info.get('url')
    if not source_url or urlparse(source_url).hostname not in ('upload.wikimedia.org', 'thumb.wikimedia.org'):
        return None
    return {'file_title': page['title'], 'source_page': info['descriptionurl'],
        'download_url': source_url, 'original_url': info['url'], 'original_sha1': info.get('sha1'),
        'license': license_name, 'license_url': license_url, 'author': artist, 'credit': credit,
        'attribution': f'{page["title"]} — {artist} / Wikimedia Commons / {license_name}',
        'width': info.get('thumbwidth', info['width']), 'height': info.get('thumbheight', info['height']),
        'modifications': 'Wikimedia-resized thumbnail; no crop or other edit by Narat.',
        'license_review': 'API metadata checked against explicit allowlist',
        'species_visual_review': 'pending'}


def media_metadata(client, filenames):
    result = {}
    reviewed = {p['file_title']: p for p in json.loads((ROOT / 'catalogue/manifests/pilot-media.json').read_text())['assets']}
    for batch in chunks(list(dict.fromkeys(filenames)), 40):
        doc, meta = client.api('commons.wikimedia.org', action='query', titles='|'.join('File:' + s for s in batch),
            redirects=1, prop='imageinfo', iiprop='url|extmetadata|sha1|size|mime', iiurlwidth=960)
        by_title = {p['title']: p for p in doc.get('query', {}).get('pages', [])}
        aliases = {v['from']: v['to'] for v in doc.get('query', {}).get('normalized', []) + doc.get('query', {}).get('redirects', [])}
        for filename in batch:
            title = 'File:' + filename
            visited = set()
            while title in aliases and title not in visited:
                visited.add(title)
                title = aliases[title]
            page = by_title.get(title, {})
            previous = reviewed.get(title)
            prior_author = None
            if previous:
                expected = {'CC-BY-SA-3.0': 'CC BY-SA 3.0', 'CC0-1.0': 'CC0'}.get(previous['license'])
                reported = (page.get('imageinfo') or [{}])[0].get('extmetadata', {}).get('LicenseShortName', {}).get('value')
                if expected and reported == expected:
                    prior_author = previous['author']
            image = permitted_image(page, prior_author)
            if image:
                result[filename] = {**image, 'metadata_snapshot': meta,
                    'prior_attribution_review': 'catalogue/manifests/pilot-media.json' if prior_author else None}
        print(f'licensed media candidates {len(result)}', flush=True)
    return result


def download_image(client, image):
    extension = Path(urlparse(image['download_url']).path).suffix.lower()
    filename = sha(image['download_url'].encode())[:24] + extension
    target = OUT / 'media' / filename
    raw, meta = client.request(image['download_url'], target, binary=True)
    width, height, mime = parse_image_dimensions_and_mime(raw)
    return {**image, 'local_path': str(target.relative_to(ROOT)), 'sha256': sha(raw),
            'bytes': len(raw), 'width': width, 'height': height, 'mime': mime,
            'retrieved_at': meta['retrieved_at']}


def strip_parens(text):
    out = []
    depth = 0
    for ch in text:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth = max(0, depth - 1)
        elif depth == 0:
            out.append(ch)
    return ''.join(out)


def parse_plantfolio_examples(common_examples):
    ce_clean = re.sub(r"'[^']*'", '', common_examples or '')
    syn_clauses = re.findall(r'\b(?:syn\.|formerly)\s*([^;()]+)', ce_clean, flags=re.I)
    outside = strip_parens(ce_clean)
    primary_binomials, synonym_binomials, genera = [], [], []
    last_genus = None

    def add_from_clause(clause, target_list):
        nonlocal last_genus
        for part in clause.split(','):
            part = part.strip()
            if not part:
                continue
            m_full = re.match(
                r'^([A-Z][a-z]+)\s+(?:×\s*)?([a-z][a-z-]+)'
                r'(?:\s+(?:var\.|subsp\.|f\.)\s+([a-z][a-z-]+))?'
                r'(?:\s+(?:var\.|subsp\.|f\.)\s+([a-z][a-z-]+))?$',
                part,
            )
            if (
                m_full
                and m_full.group(1).lower() not in ENGLISH_EXAMPLE_WORDS
                and m_full.group(2).lower() not in ENGLISH_EXAMPLE_WORDS
            ):
                last_genus = m_full.group(1)
                sp = f'{last_genus} {m_full.group(2)}'.lower()
                if sp not in target_list:
                    target_list.append(sp)
                if last_genus.lower() not in genera:
                    genera.append(last_genus.lower())
                for g_idx in (3, 4):
                    if m_full.group(g_idx):
                        sp2 = f'{last_genus} {m_full.group(g_idx)}'.lower()
                        if sp2 not in target_list:
                            target_list.append(sp2)
                continue
            m_abbr = re.match(
                r'^([A-Z])\.\s*(?:×\s*)?([a-z][a-z-]+)'
                r'(?:\s+(?:var\.|subsp\.|f\.)\s+([a-z][a-z-]+))?$',
                part,
            )
            if (
                m_abbr
                and last_genus
                and last_genus[0] == m_abbr.group(1)
                and m_abbr.group(2).lower() not in ENGLISH_EXAMPLE_WORDS
            ):
                sp = f'{last_genus} {m_abbr.group(2)}'.lower()
                if sp not in target_list:
                    target_list.append(sp)
                if m_abbr.group(3):
                    sp2 = f'{last_genus} {m_abbr.group(3)}'.lower()
                    if sp2 not in target_list:
                        target_list.append(sp2)
                continue
            m_gen = re.match(r'^([A-Z][a-z]+)(?:\s+spp\.|\s+hybrids)?$', part)
            if m_gen and m_gen.group(1).lower() not in ENGLISH_EXAMPLE_WORDS:
                last_genus = m_gen.group(1)
                if last_genus.lower() not in genera:
                    genera.append(last_genus.lower())

    add_from_clause(outside, primary_binomials)
    for syn_str in syn_clauses:
        add_from_clause(syn_str, synonym_binomials)
    return primary_binomials, synonym_binomials, genera


def load_plantfolio_index(plantfolio_dir=PLANTFOLIO_DIR):
    manifest = json.loads((plantfolio_dir / 'manifest.json').read_text())
    dist_path = plantfolio_dir / 'dist/common_plants.json'
    raw = dist_path.read_bytes()
    dist_sha = sha(raw)
    expected_sha = next(f['sha256'] for f in manifest['files'] if f['path'] == 'dist/common_plants.json')
    if dist_sha != expected_sha:
        raise ValueError('Plantfolio common_plants.json SHA256 mismatch')
    entries = [p for p in json.loads(raw) if 'id' in p]
    parsed = {p['id']: parse_plantfolio_examples(p.get('commonExamples', '')) for p in entries}
    by_id = {p['id']: p for p in entries}
    by_primary = {}
    by_syn = {}
    for p in entries:
        pb, sb, _ = parsed[p['id']]
        for b in pb:
            by_primary.setdefault(b, []).append(p)
        for b in sb:
            by_syn.setdefault(b, []).append(p)
    return {
        'manifest': manifest,
        'dist_sha256': dist_sha,
        'by_id': by_id,
        'by_primary': by_primary,
        'by_syn': by_syn,
        'parsed': parsed,
    }


def select_plantfolio_entry(entries, sci_name, parsed, c_names=None):
    c_names = c_names or set()
    slug = sci_name.lower().replace(' ', '-')
    genus = sci_name.split()[0].lower()

    def score(entry):
        pb, sb, gen = parsed[entry['id']]
        id_exact = entry['id'] == slug
        not_broad = entry['id'] not in BROAD_CATEGORY_IDS
        single_genus = len(gen) <= 1
        lead_exact = bool(re.match(r'^' + re.escape(sci_name) + r"\b(?!\s*(?:'|var\.|subsp\.))", entry.get('commonExamples', ''), flags=re.I))
        unquoted = bool(re.search(r'\b' + re.escape(sci_name) + r"\b(?!\s*(?:'|var\.|subsp\.))", entry.get('commonExamples', ''), flags=re.I))
        tn = entry.get('typeName', '').lower()
        tn_match = tn in c_names or tn.rstrip('s') in c_names
        genus_in_id = genus in entry['id']
        is_houseplant = entry.get('category', '').startswith(('Houseplants', 'Specialty'))
        return (id_exact, not_broad, lead_exact, tn_match, unquoted, single_genus, genus_in_id, is_houseplant, -len(pb))

    return sorted(entries, key=score, reverse=True)[0]


def match_plantfolio_watering(record, index):
    sci_name = record['scientific_name']
    sci_lower = sci_name.lower()
    c_names = (
        {n['name'].lower() for n in record.get('common_names', {}).get('en', [])}
        | {a.lower() for a in record.get('search_aliases', {}).get('en', [])}
    )
    selected = None
    match_level = None
    matched_on = None

    if sci_lower in index['by_primary']:
        selected = select_plantfolio_entry(index['by_primary'][sci_lower], sci_name, index['parsed'], c_names)
        match_level = 'species_exact'
        matched_on = sci_name
    elif sci_lower in index['by_syn']:
        selected = select_plantfolio_entry(index['by_syn'][sci_lower], sci_name, index['parsed'], c_names)
        match_level = 'species_synonym'
        matched_on = sci_name
    else:
        aliases = record.get('search_aliases', {}).get('en', []) + record.get('search_aliases', {}).get('pl', [])
        hit_alias = [a for a in aliases if a.lower() in index['by_primary'] or a.lower() in index['by_syn']]
        if hit_alias:
            matched_on = hit_alias[0]
            pool = index['by_primary'].get(matched_on.lower()) or index['by_syn'].get(matched_on.lower())
            selected = select_plantfolio_entry(pool, matched_on, index['parsed'], c_names)
            match_level = 'species_synonym'
        else:
            intro_text = (record.get('descriptions', {}).get('en') or {}).get('text', '')
            intro_lead = re.split(r'\bis\s+(?:a|an|the)\b', intro_text[:450], maxsplit=1, flags=re.I)[0]
            syn_mentions = re.findall(
                r'\b(?:synonym|formerly|previously|also classified as|basionym)[^.]{0,120}',
                intro_text,
                flags=re.I,
            )
            search_text = intro_lead + ' ' + ' '.join(syn_mentions)
            intro_bins = [
                f'{m.group(1)} {m.group(2)}'
                for m in re.finditer(r'\b([A-Z][a-z]+)\s+([a-z][a-z-]+)\b', search_text)
            ]
            hit_intro = [
                b for b in intro_bins
                if (b.lower() in index['by_primary'] or b.lower() in index['by_syn'])
                and not (sci_lower == 'dracaena hyacinthoides' and b.lower() == 'dracaena trifasciata')
            ]
            if hit_intro:
                matched_on = hit_intro[0]
                pool = index['by_primary'].get(matched_on.lower()) or index['by_syn'].get(matched_on.lower())
                selected = select_plantfolio_entry(pool, matched_on, index['parsed'], c_names)
                match_level = 'species_synonym'
            else:
                genus = sci_lower.split()[0]
                intro_lower = intro_text.lower()
                if genus == 'dracaena':
                    rep_id = 'snake-plants' if 'sansevieria' in intro_lower else 'dracaena-fragrans'
                    selected = index['by_id'].get(rep_id)
                    match_level = 'genus_representative'
                    matched_on = 'Dracaena (Sansevieria clade)' if rep_id == 'snake-plants' else 'Dracaena'
                elif genus in GENUS_GROUP_REPRESENTATIVE:
                    rep_id = GENUS_GROUP_REPRESENTATIVE[genus]
                    selected = index['by_id'].get(rep_id)
                    match_level = 'genus_representative'
                    matched_on = sci_name.split()[0]
                elif genus in BOTANICAL_GROUP_FALLBACK:
                    rep_id, group_label = BOTANICAL_GROUP_FALLBACK[genus]
                    selected = index['by_id'].get(rep_id)
                    match_level = 'botanical_group_representative'
                    matched_on = group_label

    if not selected:
        return None

    return {
        'intervals_days': {
            'spring': selected.get('springInterval'),
            'summer': selected.get('summerInterval'),
            'fall': selected.get('fallInterval'),
            'winter': selected.get('winterInterval'),
        },
        'watering_method': selected.get('wateringMethod'),
        'drainage_preference': selected.get('drainagePreference'),
        'match_level': match_level,
        'matched_on': matched_on,
        'source': {
            'id': 'plantfolio_common_plants',
            'repository': index['manifest']['repository'],
            'commit': index['manifest']['commit'],
            'snapshot_sha256': index['dist_sha256'],
            'plantfolio_id': selected['id'],
            'plantfolio_type_name': selected.get('typeName'),
            'plantfolio_common_examples': selected.get('commonExamples'),
        },
    }


def resolved_taxon(item):
    if item.get('id') in WIKIDATA_P225_CORRECTIONS:
        ranks = list(dict.fromkeys(v.get('id') for v in values(item, 'P105') if isinstance(v, dict)))
        if ranks == [SPECIES_RANK]:
            return WIKIDATA_P225_CORRECTIONS[item['id']]
    return taxon(item)


def run(args):
    registry = json.loads((ROOT / 'knowledge-base/manifests/source-registry.json').read_text())
    operations = ['store_raw', 'commercial_use'] + ([] if args.offline else ['automated_fetch'])
    for source in ('wikidata_structured', 'wikipedia_catalogue_text', 'wikimedia_commons_catalogue'):
        require_operations(registry, source, operations)
    require_operations(registry, 'wikipedia_catalogue_text', ['translate'])
    require_operations(registry, 'plantfolio_common_plants', ['manual_reference', 'store_raw', 'derive_facts'])
    plantfolio_index = load_plantfolio_index()
    pl_translations_path = ROOT / 'knowledge-base/manifests/pl-description-translations.json'
    pl_translations = json.loads(pl_translations_path.read_text()) if pl_translations_path.exists() else {}
    client = Client(args.user_agent, args.offline)
    titles = discover(client)
    base_titles = titles[:604]
    extra_titles = titles[604:]
    english = articles(client, 'en', base_titles)
    items = entities(client, [p['pageprops']['wikibase_item'] for p in english.values() if p.get('pageprops', {}).get('wikibase_item')])
    by_qid = {p['pageprops']['wikibase_item']: p for p in english.values() if p.get('pageprops', {}).get('wikibase_item')}
    # Monotypic genus articles can describe a species but their page item is the genus.
    # Resolve only exact scientific-name matches; never silently turn a genus into a species.
    missing_priorities = [t for t in base_titles[:95] if not any(taxon(e) == t for e in items.values())]
    for title in missing_priorities:
        doc, meta = client.api('www.wikidata.org', action='wbsearchentities', search=title, language='en', type='item', limit=5)
        hits = entities(client, [h['id'] for h in doc.get('search', [])]) if doc.get('search') else {}
        exact = [e for e in hits.values() if taxon(e) == title]
        if len(exact) == 1:
            item = exact[0]
            items[item['id']] = item
            linked = item.get('sitelinks', {}).get('enwiki', {}).get('title')
            if linked in english:
                by_qid[item['id']] = english[linked]
            # Genus article may mention this binomial; require explicit statement, record scope.
            elif item['id'] not in by_qid:
                for page in english.values():
                    if title in page.get('extract', '') and ('only species' in page.get('extract', '').lower() or 'single species' in page.get('extract', '').lower()):
                        by_qid[item['id']] = page
                        break
    def priority(item):
        name = taxon(item) or resolved_taxon(item)
        page = by_qid.get(item['id'], {})
        candidates = [titles.index(t) for t in (name, page.get('title')) if t in titles]
        return min(candidates, default=len(titles))
    candidates = []
    rejected = []
    seen_names = set()
    for item in sorted(items.values(), key=priority):
        name = taxon(item)
        page = by_qid.get(item['id'])
        if not name or not page or not description(page, 'en') or norm(name) in seen_names:
            rejected.append({'qid': item.get('id'), 'reason': 'not_unique_species_or_missing_description', 'names': values(item, 'P225')})
            continue
        seen_names.add(norm(name))
        if item['id'] in WIKIDATA_P225_CORRECTIONS:
            seen_names.add(norm(WIKIDATA_P225_CORRECTIONS[item['id']]))
        images = list(dict.fromkeys(values(item, 'P18') + ([page['pageimage']] if page.get('pageimage') else [])))
        candidates.append((item, page, images))
    metadata = media_metadata(client, [f for _, _, images in candidates for f in images[:3]])

    # Second wave: recover monotypic/corrupted-P225 items from base and fetch extra popular Plantfolio species
    if 'Q135499' in items and 'Ludisia' in english and 'Q135499' not in by_qid:
        by_qid['Q135499'] = english['Ludisia']
    if extra_titles:
        extra_en = articles(client, 'en', extra_titles)
        english.update(extra_en)
        extra_qids = [
            p['pageprops']['wikibase_item']
            for p in extra_en.values()
            if p.get('pageprops', {}).get('wikibase_item') and p['pageprops']['wikibase_item'] not in items
        ]
        if extra_qids:
            items.update(entities(client, extra_qids))
        for p in extra_en.values():
            qid = p.get('pageprops', {}).get('wikibase_item')
            if qid and qid not in by_qid:
                by_qid[qid] = p
    monotypic_check = [
        t for t in ('Chamaerops humilis', 'Fenestraria rhopalophylla', 'Darlingtonia californica', 'Welwitschia mirabilis', 'Carnegiea gigantea')
        if t in titles and not any(resolved_taxon(e) == t for e in items.values())
    ]
    for title in monotypic_check:
        doc, meta = client.api('www.wikidata.org', action='wbsearchentities', search=title, language='en', type='item', limit=5)
        hits = entities(client, [h['id'] for h in doc.get('search', [])]) if doc.get('search') else {}
        exact = [e for e in hits.values() if resolved_taxon(e) == title]
        if len(exact) == 1:
            item = exact[0]
            items[item['id']] = item
            linked = item.get('sitelinks', {}).get('enwiki', {}).get('title')
            if linked in english:
                by_qid[item['id']] = english[linked]
            elif item['id'] not in by_qid:
                for page in english.values():
                    ext_low = page.get('extract', '').lower()
                    if title in page.get('extract', '') and any(k in ext_low for k in ('only species', 'single species', 'one species', 'monotypic')):
                        by_qid[item['id']] = page
                        break

    extra_candidates = []
    rejected = []
    for item in sorted(items.values(), key=priority):
        name = resolved_taxon(item)
        page = by_qid.get(item['id'])
        if not name or not page or not description(page, 'en'):
            rejected.append({'qid': item.get('id'), 'reason': 'not_unique_species_or_missing_description', 'names': values(item, 'P225')})
            continue
        if norm(name) in seen_names:
            # Check if Syngonium podophyllum was in candidates without licensed media
            if item['id'] == 'Q13403357' and 'Q2448411' in items:
                syn_imgs = list(dict.fromkeys(values(items['Q2448411'], 'P18') + values(item, 'P18')))
                extra_candidates.append((item, page, syn_imgs))
            continue
        seen_names.add(norm(name))
        images = list(dict.fromkeys(values(item, 'P18') + ([page['pageimage']] if page.get('pageimage') else [])))
        extra_candidates.append((item, page, images))

    extra_files = [f for _, _, images in extra_candidates for f in images[:3] if f not in metadata]
    if extra_files:
        metadata.update(media_metadata(client, extra_files))

    # Merge candidates with extra_candidates (updating Syngonium podophyllum images if needed)
    extra_by_qid = {item['id']: (item, page, images) for item, page, images in extra_candidates}
    merged_candidates = []
    seen_qids = set()
    for item, page, images in candidates:
        if item['id'] in extra_by_qid:
            item, page, images = extra_by_qid[item['id']]
        merged_candidates.append((item, page, images))
        seen_qids.add(item['id'])
    for item, page, images in extra_candidates:
        if item['id'] not in seen_qids:
            merged_candidates.append((item, page, images))
            seen_qids.add(item['id'])

    eligible = [(item, page, images) for item, page, images in merged_candidates if any(i in metadata for i in images[:3])]
    target_count = args.count if args.count > 0 else len(eligible)
    if len(eligible) < target_count:
        raise ValueError(f'Only {len(eligible)} eligible species; need {target_count}')
    selected = eligible[:target_count]
    base_pl_titles = [e.get('sitelinks', {}).get('plwiki', {}).get('title') for e, _, _ in selected[:300]]
    polish = articles(client, 'pl', [t for t in base_pl_titles if t])
    extra_pl_titles = [
        e.get('sitelinks', {}).get('plwiki', {}).get('title')
        for e, _, _ in selected[300:]
    ]
    extra_pl_titles = [t for t in extra_pl_titles if t and t not in polish]
    if extra_pl_titles:
        polish.update(articles(client, 'pl', extra_pl_titles))
    records = []
    scientific_genera = {name.split()[0].casefold() for e in items.values() for name in values(e, 'P225') if isinstance(name, str)}
    for item, page, images in selected:
        name = resolved_taxon(item)
        image = next(metadata[i] for i in images[:3] if i in metadata)
        image = download_image(client, image)
        names = common_names(item, name, scientific_genera)
        existing_en = {norm(n['name']) for n in names['en']}
        for extracted in intro_common_names(page, [a['value'] for a in item.get('aliases', {}).get('en', [])], scientific_genera):
            if norm(extracted['name']) not in existing_en:
                names['en'].append(extracted)
                existing_en.add(norm(extracted['name']))
        pl_title = item.get('sitelinks', {}).get('plwiki', {}).get('title')
        pl_page = eligible_polish_article(item, polish.get(pl_title))
        plant_id = name.lower().replace(' ', '_').replace('-', '_')
        pl_entry = pl_translations.get(plant_id)
        pl_desc = description(pl_page, 'pl') or translated_description(page, pl_entry)
        names['pl'].extend(translated_pl_common_names(page, pl_entry, item, name, names['pl'], scientific_genera))
        record = {'plant_id': plant_id,
            'scientific_name': name, 'scientific_name_status': 'Wikidata species name; accepted-taxonomy audit pending',
            'wikidata_id': item['id'], 'source_revision': item['lastrevid'],
            'external_taxon_ids': {prop: values(item, prop) for prop in ('P846', 'P961', 'P5037')},
            'common_names': names,
            'search_aliases': {lang: [a['value'] for a in item.get('aliases', {}).get(lang, [])
                if lang == 'en' or polish_name_is_eligible(a['value'], item['id'])] for lang in ('en', 'pl')},
            'descriptions': {'en': description(page, 'en'), 'pl': pl_desc},
            'hero_image': image, 'watering': None, 'care_profile_available': False,
            'status': 'imported_editorial_review_pending',
            'name_source': {'url': f'https://www.wikidata.org/wiki/{item["id"]}', 'license': 'CC0-1.0', 'snapshot': item['_snapshot']}}
        en_qid = record['descriptions']['en']['article_wikidata_id']
        record['descriptions']['en']['taxon_scope'] = ('species' if en_qid == item['id']
            else 'monotypic_genus_article_explicitly_names_species')
        record['watering'] = match_plantfolio_watering(record, plantfolio_index)
        record['gaps'] = []
        for lang in ('en', 'pl'):
            if not names[lang]: record['gaps'].append('common_names_' + lang)
            if not record['descriptions'][lang]: record['gaps'].append('description_' + lang)
        if not record['watering']:
            record['gaps'].append('watering')
        records.append(record)
        print(f'media {len(records)}/{len(selected)} {name}', flush=True)
        dump(OUT / 'progress.json', {'completed': len(records), 'target': target_count})
    if len({r['plant_id'] for r in records}) != target_count:
        raise ValueError('Plant ID collision')
    report = {'records': len(records), 'unique_qids': len({r['wikidata_id'] for r in records}),
        'description_en': sum(bool(r['descriptions']['en']) for r in records),
        'description_pl': sum(bool(r['descriptions']['pl']) for r in records),
        'description_pl_native': sum(bool(r['descriptions']['pl']) and not r['descriptions']['pl'].get('translation_source_language') for r in records),
        'description_pl_translated': sum((r['descriptions']['pl'] or {}).get('translation_source_language') == 'en' for r in records),
        'common_names_en': sum(bool(r['common_names']['en']) for r in records),
        'common_names_pl': sum(bool(r['common_names']['pl']) for r in records),
        'watering_total': sum(bool(r['watering']) for r in records),
        'watering_species_exact': sum((r['watering'] or {}).get('match_level') == 'species_exact' for r in records),
        'watering_species_synonym': sum((r['watering'] or {}).get('match_level') == 'species_synonym' for r in records),
        'watering_genus_representative': sum((r['watering'] or {}).get('match_level') == 'genus_representative' for r in records),
        'watering_botanical_group_representative': sum((r['watering'] or {}).get('match_level') == 'botanical_group_representative' for r in records),
        'watering_missing': sum(not r['watering'] for r in records),
        'downloaded_images': len(records), 'media_bytes': sum(r['hero_image']['bytes'] for r in records),
        'editorial_review': 'pending for all records', 'live_application_integration': 'not_run',
        'gaps': [{'plant_id': r['plant_id'], 'missing': r['gaps']} for r in records if r['gaps']],
        'eligible_candidates': len(eligible), 'excluded': rejected}
    dump(OUT / 'plants.json', {'schema_version': 'catalogue-skeleton-1.1', 'version': 'skeleton-300-v1',
        'status': 'imported_not_published',
        'sources': ['Wikidata', 'English/Polish Wikipedia', 'Wikimedia Commons', 'Plantfolio Common Plants'],
        'plants': records})
    dump(OUT / 'coverage.json', report)
    db_path = ROOT / 'knowledge-base/staging/catalogue-300.sqlite'
    db_path.parent.mkdir(parents=True, exist_ok=True)
    from contextlib import closing
    with closing(sqlite3.connect(db_path)) as db, db:
        db.execute('CREATE TABLE IF NOT EXISTS catalogue_skeleton (plant_id TEXT PRIMARY KEY, wikidata_id TEXT UNIQUE NOT NULL, scientific_name TEXT NOT NULL, payload_json TEXT NOT NULL)')
        db.execute('DELETE FROM catalogue_skeleton')
        db.executemany('INSERT INTO catalogue_skeleton VALUES (?,?,?,?)', [(r['plant_id'], r['wikidata_id'], r['scientific_name'], json.dumps(r, ensure_ascii=False, sort_keys=True)) for r in records])
    dump(OUT / 'manifest.json', {'version': 'skeleton-300-v1', 'records': len(records),
        'plants_sha256': sha((OUT / 'plants.json').read_bytes()),
        'coverage_sha256': sha((OUT / 'coverage.json').read_bytes()),
        'media': [{'path': r['hero_image']['local_path'], 'sha256': r['hero_image']['sha256']} for r in records]})
    print(json.dumps({k: v for k, v in report.items() if k not in ('gaps', 'excluded')}, ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--user-agent')
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--count', type=int, default=0)
    args = parser.parse_args()
    if args.count < 0: parser.error('--count must be non-negative')
    run(args)


if __name__ == '__main__':
    main()
