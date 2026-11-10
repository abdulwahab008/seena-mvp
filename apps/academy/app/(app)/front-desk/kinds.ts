export const FRONT_DESK_KINDS = ['visitor', 'call', 'appointment', 'parcel', 'gate_pass', 'lost_found', 'complaint', 'contact'] as const;
export type FrontDeskKind = (typeof FRONT_DESK_KINDS)[number];

type Field = 'phone' | 'purpose' | 'host_name' | 'reference' | 'details' | 'follow_up_on';

export const KIND_CONFIG: Record<FrontDeskKind, { tab: string; person: string; fields: Partial<Record<Field, string>>; open: string; close: string }> = {
  visitor: { tab: 'Visitors', person: 'Visitor name', fields: { phone: 'Mobile', purpose: 'Purpose of visit', host_name: 'Meeting', reference: 'CNIC / ID number' }, open: 'Inside', close: 'Sign out' },
  call: { tab: 'Calls', person: 'Caller', fields: { phone: 'Number', purpose: 'Call about', host_name: 'For', details: 'Summary', follow_up_on: 'Follow up on' }, open: 'Open', close: 'Done' },
  appointment: { tab: 'Appointments', person: 'Visitor', fields: { phone: 'Mobile', purpose: 'Purpose', host_name: 'Meeting with', follow_up_on: 'Date', details: 'Time and notes' }, open: 'Booked', close: 'Done' },
  parcel: { tab: 'Parcels', person: 'Recipient', fields: { phone: 'Recipient mobile', purpose: 'Contents', host_name: 'Courier', reference: 'Tracking number' }, open: 'Waiting', close: 'Collected' },
  gate_pass: { tab: 'Gate passes', person: 'Student or staff name', fields: { phone: 'Guardian mobile', purpose: 'Reason', host_name: 'Authorised by', reference: 'Pass number' }, open: 'Out', close: 'Returned' },
  lost_found: { tab: 'Lost & found', person: 'Item', fields: { phone: 'Contact mobile', purpose: 'Where found or lost', host_name: 'Reported by', details: 'Description' }, open: 'Unclaimed', close: 'Claimed' },
  complaint: { tab: 'Complaints', person: 'Complaint by', fields: { phone: 'Mobile', purpose: 'Subject', host_name: 'Complaint against', reference: 'Category', details: 'Details', follow_up_on: 'Respond by' }, open: 'Open', close: 'Resolve' },
  contact: { tab: 'People directory', person: 'Name', fields: { phone: 'Mobile', purpose: 'Group (supplier, plumber, doctor...)', host_name: 'Company', details: 'Notes' }, open: 'Saved', close: 'Remove' },
};

export const FRONT_DESK_ROLES = ['super_admin', 'owner', 'principal', 'vice_principal', 'admissions_officer', 'receptionist'];
