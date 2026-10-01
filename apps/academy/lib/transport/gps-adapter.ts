// FR-P06: the isolated seam between a tracker vendor's webhook and the ingest RPC.
//
// Most cheap trackers push to the vendor's cloud, which then forwards batches to
// us. Each vendor shapes its payload differently, so the route hands the parsed
// JSON to an adapter that returns plain pings; nothing downstream knows about any
// vendor. Two adapters ship: the documented generic format (also what a dev
// simulator or an in-house device posts) and a Traccar-forwarder shape. A new
// vendor is one more object implementing GpsVendorAdapter. No vendor account,
// credential or endpoint is assumed here.

export type GpsPing = {
  vehicle_id?: string;
  reg_no?: string;
  lat: number;
  lng: number;
  speed_kmh?: number;
  heading?: number;
  /** ISO-8601 instant of the fix, as measured by the device. */
  device_ts: string;
};

export interface GpsVendorAdapter {
  readonly name: string;
  /** Throws GpsPayloadError on a payload it cannot read. Pings may arrive out of order. */
  parse(body: unknown): GpsPing[];
}

export class GpsPayloadError extends Error {}

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

/** ISO strings, epoch seconds and epoch milliseconds all become an ISO instant. */
export function toIsoInstant(v: unknown): string {
  let ms: number;
  if (typeof v === 'number') ms = v < 1e11 ? v * 1000 : v;
  else if (typeof v === 'string' && /^\d+(\.\d+)?$/.test(v.trim())) ms = Number(v) < 1e11 ? Number(v) * 1000 : Number(v);
  else if (typeof v === 'string') ms = Date.parse(v);
  else throw new GpsPayloadError('Missing timestamp');
  if (!Number.isFinite(ms)) throw new GpsPayloadError('Unreadable timestamp');
  return new Date(ms).toISOString();
}

const num = (v: unknown, what: string): number => {
  const n = typeof v === 'string' ? Number(v) : v;
  if (typeof n !== 'number' || !Number.isFinite(n)) throw new GpsPayloadError(`Missing ${what}`);
  return n;
};
const optNum = (v: unknown): number | undefined => {
  const n = typeof v === 'string' ? Number(v) : v;
  return typeof n === 'number' && Number.isFinite(n) ? n : undefined;
};

/** { "pings": [ { "reg_no" | "vehicle_id", "lat", "lng", "speed", "heading", "ts" } ] } */
export const genericAdapter: GpsVendorAdapter = {
  name: 'generic',
  parse(body) {
    const list = isObj(body) ? body.pings : Array.isArray(body) ? body : undefined;
    if (!Array.isArray(list)) throw new GpsPayloadError('Expected { pings: [...] }');
    return list.map((p) => {
      if (!isObj(p)) throw new GpsPayloadError('Each ping must be an object');
      const reg = typeof p.reg_no === 'string' ? p.reg_no : undefined;
      const id = typeof p.vehicle_id === 'string' ? p.vehicle_id : undefined;
      if (!reg && !id) throw new GpsPayloadError('Each ping needs reg_no or vehicle_id');
      return {
        reg_no: reg, vehicle_id: id,
        lat: num(p.lat, 'lat'), lng: num(p.lng ?? p.lon, 'lng'),
        speed_kmh: optNum(p.speed_kmh ?? p.speed), heading: optNum(p.heading ?? p.course),
        device_ts: toIsoInstant(p.device_ts ?? p.ts ?? p.time),
      };
    });
  },
};

/** Traccar event-forwarding shape: { device: { name }, position: { latitude, longitude, speed (knots), course, deviceTime } }. The device name carries the registration. */
export const traccarAdapter: GpsVendorAdapter = {
  name: 'traccar',
  parse(body) {
    const items = Array.isArray(body) ? body : [body];
    return items.map((it) => {
      if (!isObj(it) || !isObj(it.device) || !isObj(it.position)) throw new GpsPayloadError('Expected { device, position }');
      const reg = typeof it.device.name === 'string' ? it.device.name : undefined;
      if (!reg) throw new GpsPayloadError('Device has no name');
      const knots = optNum(it.position.speed);
      return {
        reg_no: reg,
        lat: num(it.position.latitude, 'latitude'), lng: num(it.position.longitude, 'longitude'),
        speed_kmh: knots === undefined ? undefined : Math.round(knots * 1.852 * 10) / 10,
        heading: optNum(it.position.course),
        device_ts: toIsoInstant(it.position.deviceTime ?? it.position.fixTime),
      };
    });
  },
};

const ADAPTERS: Record<string, GpsVendorAdapter> = { generic: genericAdapter, traccar: traccarAdapter };
export function adapterFor(name: string | null | undefined): GpsVendorAdapter | null {
  return ADAPTERS[name ?? 'generic'] ?? null;
}
