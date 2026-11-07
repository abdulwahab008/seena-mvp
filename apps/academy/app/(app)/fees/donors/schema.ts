import { z } from 'zod';

const RUPEES = /^\d+(\.\d{1,2})?$/;

export const donorSchema = z.object({ name: z.string().trim().min(1, 'Enter the name').max(150), phone: z.string().trim().max(30) });
export const donationSchema = z.object({
  donorId: z.string().min(1, 'Choose a donor'),
  amount: z.string().regex(RUPEES, 'Enter the amount in rupees'),
  receivedOn: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a date'),
  mode: z.enum(['cash', 'bank', 'cheque', 'online']),
  purpose: z.enum(['general', 'zakat', 'sadaqah', 'building', 'sponsorship']),
  reference: z.string().trim().max(100),
});
export const sponsorshipSchema = z.object({
  donorId: z.string().min(1, 'Choose a donor'),
  grNumber: z.string().trim().min(1, 'Enter the GR number'),
  monthly: z.string().regex(RUPEES, 'Enter the monthly amount in rupees'),
});
export type DonorInput = z.infer<typeof donorSchema>;
export type DonationInput = z.infer<typeof donationSchema>;
export type SponsorshipInput = z.infer<typeof sponsorshipSchema>;
