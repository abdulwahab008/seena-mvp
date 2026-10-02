import { parseAmountToPaisa, parseCsv, parseDate, type DateFormat } from '@/lib/bank/parse-statement';

export type SettlementLine = {
  line_no: number;
  gateway_txn_id: string | null;
  settlement_date: string | null;
  gross_paisa: number | null;
  commission_paisa: number | null;
  net_paisa: number | null;
  raw_line: string;
  error: string | null;
};

// Gateway exports name the same columns differently; field mapping per
// gateway is a sandbox-credential task, so headers are matched by alias.
const ALIASES = {
  txn: ['transactionid', 'txnid', 'gatewaytxnid', 'txnrefno', 'pptxnrefno', 'reference', 'referenceno', 'transactionref'],
  date: ['settlementdate', 'settleddate', 'settledon', 'valuedate', 'date'],
  gross: ['gross', 'grossamount', 'transactionamount', 'txnamount', 'amount'],
  commission: ['commission', 'fee', 'fees', 'mdr', 'charges', 'servicecharges', 'deduction'],
  net: ['net', 'netamount', 'settledamount', 'settlementamount', 'payout'],
} as const;

const DATE_FORMATS: DateFormat[] = ['YYYY-MM-DD', 'DD/MM/YYYY', 'DD-MM-YYYY', 'DD-Mon-YYYY'];
const norm = (h: string) => h.toLowerCase().replace(/[^a-z0-9]/g, '');

function findColumn(header: string[], aliases: readonly string[]): number {
  const normalised = header.map(norm);
  for (const a of aliases) {
    const i = normalised.indexOf(a);
    if (i >= 0) return i;
  }
  return -1;
}

function parseAnyDate(s: string): string | null {
  for (const f of DATE_FORMATS) {
    const d = parseDate(s, f);
    if (d) return d;
  }
  return null;
}

export function parseSettlement(csv: string): { lines: SettlementLine[]; fatal: string | null } {
  const rows = parseCsv(csv);
  const header = (rows[0] ?? []).map((h) => h.trim());
  const col = { txn: findColumn(header, ALIASES.txn), date: findColumn(header, ALIASES.date), gross: findColumn(header, ALIASES.gross), commission: findColumn(header, ALIASES.commission), net: findColumn(header, ALIASES.net) };
  const missing = [col.txn < 0 && 'transaction id', col.date < 0 && 'settlement date', col.gross < 0 && 'gross amount', col.commission < 0 && col.net < 0 && 'commission or net amount'].filter(Boolean);
  if (missing.length > 0) return { lines: [], fatal: `Columns not found in the file: ${missing.join(', ')}` };

  const lines = rows.slice(1).map((r, idx): SettlementLine => {
    const line_no = idx + 2;
    const raw_line = r.join(',');
    const get = (i: number) => (i >= 0 ? (r[i] ?? '').trim() : '');
    const errors: string[] = [];

    const gateway_txn_id = get(col.txn) || null;
    if (!gateway_txn_id) errors.push('MISSING_TXN_ID');
    const settlement_date = parseAnyDate(get(col.date));
    if (!settlement_date) errors.push('BAD_DATE');
    const gross = parseAmountToPaisa(get(col.gross));
    if (gross === null || gross <= 0) errors.push('BAD_GROSS');
    let commission = col.commission >= 0 ? parseAmountToPaisa(get(col.commission) || '0') : null;
    let net = col.net >= 0 ? parseAmountToPaisa(get(col.net)) : null;
    if (col.commission >= 0 && (commission === null || commission < 0)) errors.push('BAD_COMMISSION');
    if (col.net >= 0 && (net === null || net < 0)) errors.push('BAD_NET');

    if (errors.length === 0 && gross !== null) {
      if (col.commission >= 0 && col.net < 0) net = gross - (commission ?? 0);
      else if (col.net >= 0 && col.commission < 0) commission = gross - (net ?? 0);
      if (commission === null || net === null || commission < 0 || net < 0 || gross !== commission + net) errors.push('AMOUNTS_DO_NOT_ADD_UP');
    }
    if (errors.length > 0) return { line_no, gateway_txn_id: null, settlement_date: null, gross_paisa: null, commission_paisa: null, net_paisa: null, raw_line, error: errors.join(',') };
    return { line_no, gateway_txn_id, settlement_date, gross_paisa: gross, commission_paisa: commission, net_paisa: net, raw_line, error: null };
  });
  return { lines, fatal: null };
}
