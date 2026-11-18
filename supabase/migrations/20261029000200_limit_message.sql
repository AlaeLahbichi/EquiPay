-- Message de limite d'activités : formulation quand l'offre suivante est illimitée
create or replace function public.activity_limit_message(p_plan text, p_limit int)
returns text language sql immutable set search_path = '' as $$
  select format('Ton offre %s permet %s activités en cours. ', public.plan_label(p_plan), p_limit)
      || case
           when public.next_plan(p_plan) is null then 'Archive une activité terminée pour en créer une nouvelle.'
           when public.plan_limit(public.next_plan(p_plan), 'activities') is null then
             format('Passe à l''offre %s pour des activités illimitées, ou archive une activité terminée.',
                    public.plan_label(public.next_plan(p_plan)))
           else format('Passe à l''offre %s pour en avoir %s, ou archive une activité terminée.',
                       public.plan_label(public.next_plan(p_plan)),
                       public.plan_limit(public.next_plan(p_plan), 'activities'))
         end;
$$;
