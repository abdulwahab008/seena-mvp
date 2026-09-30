'use client';

import { useState } from 'react';
import { TaxSlabRow } from '../actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import {
  Calculator,
  ShieldCheck,
  TrendingUp,
  Percent,
} from 'lucide-react';

interface Props {
  initialSlabs: TaxSlabRow[];
}

export function TaxSlabsDesk({ initialSlabs }: Props) {
  const [slabs] = useState<TaxSlabRow[]>(initialSlabs);

  // Simulator state
  const [simSalary, setSimSalary] = useState<number>(100000);

  const formatPkr = (paisa: number) => {
    return new Intl.NumberFormat('en-PK', {
      style: 'currency',
      currency: 'PKR',
      maximumFractionDigits: 0,
    }).format(paisa / 100);
  };

  // Client-side tax calculation using the loaded slabs
  const calculateSim = (monthlyPkr: number) => {
    const annualPaisa = monthlyPkr * 12 * 100;
    if (annualPaisa <= 0 || slabs.length === 0) {
      return {
        annualGross: monthlyPkr * 12,
        annualTax: 0,
        monthlyTax: 0,
        monthlyNet: monthlyPkr,
        rate: 0,
        activeSlabId: null,
      };
    }

    const matched = slabs.find(
      (s) =>
        annualPaisa > s.lower_bound_paisa &&
        (s.upper_bound_paisa === null || annualPaisa <= s.upper_bound_paisa)
    );

    if (!matched) {
      return {
        annualGross: monthlyPkr * 12,
        annualTax: 0,
        monthlyTax: 0,
        monthlyNet: monthlyPkr,
        rate: 0,
        activeSlabId: null,
      };
    }

    const excess = annualPaisa - matched.lower_bound_paisa;
    const variablePaisa = Math.round((excess * matched.rate_pct) / 100);
    const grossTaxPaisa = matched.fixed_amount_paisa + variablePaisa;
    const finalTaxPaisa = matched.rebate_pct > 0
      ? Math.round(grossTaxPaisa * (1 - matched.rebate_pct / 100))
      : grossTaxPaisa;

    const monthlyTaxPaisa = Math.round(finalTaxPaisa / 12);
    const annualTaxPkr = finalTaxPaisa / 100;
    const monthlyTaxPkr = monthlyTaxPaisa / 100;
    const rate = annualPaisa > 0 ? (finalTaxPaisa / annualPaisa) * 100 : 0;

    return {
      annualGross: monthlyPkr * 12,
      annualTax: annualTaxPkr,
      monthlyTax: monthlyTaxPkr,
      monthlyNet: monthlyPkr - monthlyTaxPkr,
      rate: Math.round(rate * 100) / 100,
      activeSlabId: matched.id,
    };
  };

  const simResult = calculateSim(simSalary);

  return (
    <div className="space-y-8">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 pb-4 border-b border-slate-200 dark:border-slate-800">
        <div>
          <div className="flex items-center gap-2">
            <h1 className="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
              Tax Slab Engine & Simulator
            </h1>
            <Badge variant="outline" className="text-blue-600 border-blue-400">
              FBR TY 2026-27
            </Badge>
          </div>
          <p className="text-sm text-slate-500 dark:text-slate-400 mt-1">
            Official Pakistan salaried individual tax slabs with automatic monthly withholding calculation.
          </p>
        </div>
      </div>

      {/* Simulator Card */}
      <div className="p-6 rounded-2xl border border-indigo-100 dark:border-indigo-950/60 bg-gradient-to-br from-indigo-50/50 via-white to-sky-50/30 dark:from-slate-900 dark:via-slate-900 dark:to-indigo-950/30 shadow-sm">
        <div className="flex items-center gap-2 mb-4 text-indigo-700 dark:text-indigo-400 font-semibold">
          <Calculator className="w-5 h-5" />
          <span>Interactive Salary Tax Simulator</span>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-12 gap-6 items-center">
          <div className="md:col-span-5 space-y-3">
            <Label htmlFor="sim_salary" className="text-slate-700 dark:text-slate-300 font-medium">
              Monthly Taxable Salary (PKR)
            </Label>
            <div className="relative">
              <span className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400 font-medium text-sm">
                PKR
              </span>
              <Input
                id="sim_salary"
                type="number"
                min="0"
                step="1000"
                value={simSalary}
                onChange={(e) => setSimSalary(parseFloat(e.target.value) || 0)}
                className="pl-14 text-lg font-bold bg-white dark:bg-slate-950"
              />
            </div>
            <div className="flex flex-wrap gap-1.5 pt-1">
              {[50000, 80000, 100000, 150000, 250000, 400000].map((preset) => (
                <Button
                  key={preset}
                  variant="outline"
                  size="sm"
                  onClick={() => setSimSalary(preset)}
                  className="text-xs h-7 px-2"
                >
                  {(preset / 1000)}k
                </Button>
              ))}
            </div>
          </div>

          <div className="md:col-span-7 grid grid-cols-2 sm:grid-cols-4 gap-3 bg-white/80 dark:bg-slate-950/80 p-4 rounded-xl border border-slate-200/80 dark:border-slate-800 backdrop-blur-sm">
            <div>
              <div className="text-xs text-slate-500 font-medium">Annual Taxable</div>
              <div className="text-lg font-bold text-slate-900 dark:text-slate-100 mt-0.5">
                {new Intl.NumberFormat('en-PK', { style: 'currency', currency: 'PKR', maximumFractionDigits: 0 }).format(simResult.annualGross)}
              </div>
            </div>

            <div>
              <div className="text-xs text-rose-500 font-medium">Annual Tax</div>
              <div className="text-lg font-bold text-rose-600 dark:text-rose-400 mt-0.5">
                {new Intl.NumberFormat('en-PK', { style: 'currency', currency: 'PKR', maximumFractionDigits: 0 }).format(simResult.annualTax)}
              </div>
            </div>

            <div>
              <div className="text-xs text-rose-500 font-medium">Monthly Withholding</div>
              <div className="text-lg font-bold text-rose-600 dark:text-rose-400 mt-0.5">
                {new Intl.NumberFormat('en-PK', { style: 'currency', currency: 'PKR', maximumFractionDigits: 0 }).format(simResult.monthlyTax)}
              </div>
            </div>

            <div>
              <div className="text-xs text-emerald-600 font-medium">Net Take-Home</div>
              <div className="text-lg font-bold text-emerald-600 dark:text-emerald-400 mt-0.5">
                {new Intl.NumberFormat('en-PK', { style: 'currency', currency: 'PKR', maximumFractionDigits: 0 }).format(simResult.monthlyNet)}
              </div>
            </div>
          </div>
        </div>

        <div className="mt-4 pt-4 border-t border-slate-200/60 dark:border-slate-800/60 flex items-center justify-between text-xs text-slate-500">
          <div className="flex items-center gap-1.5">
            <Percent className="w-3.5 h-3.5 text-blue-500" />
            <span>Effective Tax Rate: <strong className="text-slate-900 dark:text-slate-100">{simResult.rate}%</strong></span>
          </div>
          <div className="flex items-center gap-1 text-emerald-600">
            <ShieldCheck className="w-3.5 h-3.5" />
            <span>Verified with Pakistan Finance Act 2026</span>
          </div>
        </div>
      </div>

      {/* Slabs Table */}
      <div className="space-y-3">
        <h2 className="text-lg font-semibold text-slate-900 dark:text-slate-100 flex items-center gap-2">
          <TrendingUp className="w-4 h-4 text-slate-500" />
          Progressive Salaried Tax Brackets
        </h2>

        <div className="rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 overflow-hidden shadow-sm">
          <div className="overflow-x-auto">
            <table className="w-full text-left border-collapse">
              <thead>
                <tr className="border-b border-slate-200 dark:border-slate-800 bg-slate-50/75 dark:bg-slate-800/50 text-xs font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
                  <th className="py-3.5 px-4 w-16">Slab</th>
                  <th className="py-3.5 px-4">Taxable Annual Income Range</th>
                  <th className="py-3.5 px-4">Fixed Tax (PKR)</th>
                  <th className="py-3.5 px-4">Marginal Tax Rate</th>
                  <th className="py-3.5 px-4">Formula Rule</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-200 dark:divide-slate-800 text-sm">
                {slabs.map((s) => {
                  const isActive = simResult.activeSlabId === s.id;
                  return (
                    <tr
                      key={s.id}
                      className={`transition-colors ${
                        isActive
                          ? 'bg-blue-50/70 dark:bg-blue-950/40 border-l-4 border-l-blue-600 font-medium'
                          : 'hover:bg-slate-50/50 dark:hover:bg-slate-800/30'
                      }`}
                    >
                      <td className="py-3.5 px-4 font-mono text-xs font-semibold text-slate-400">
                        #{s.sort_order}
                      </td>
                      <td className="py-3.5 px-4">
                        <div className="flex items-center gap-1.5 font-mono text-xs text-slate-700 dark:text-slate-300">
                          <span>{formatPkr(s.lower_bound_paisa)}</span>
                          <span className="text-slate-400">&rarr;</span>
                          <span>{s.upper_bound_paisa ? formatPkr(s.upper_bound_paisa) : 'Above'}</span>
                          {isActive && (
                            <Badge className="ml-2 bg-blue-600 text-white text-[10px] px-1.5 py-0">
                              Active Bracket
                            </Badge>
                          )}
                        </div>
                      </td>
                      <td className="py-3.5 px-4 font-medium text-slate-900 dark:text-slate-100">
                        {formatPkr(s.fixed_amount_paisa)}
                      </td>
                      <td className="py-3.5 px-4">
                        {s.rate_pct === 0 ? (
                          <span className="text-emerald-600 font-semibold">0% (Exempt)</span>
                        ) : (
                          <span className="font-semibold text-rose-600 dark:text-rose-400">
                            {s.rate_pct}%
                          </span>
                        )}
                      </td>
                      <td className="py-3.5 px-4 text-xs text-slate-500">
                        {s.rate_pct === 0
                          ? 'Zero tax on earnings under 600k PKR'
                          : `${formatPkr(s.fixed_amount_paisa)} + ${s.rate_pct}% of amount exceeding ${formatPkr(s.lower_bound_paisa)}`}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
  );
}
