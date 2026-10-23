import { type Ref, watch } from 'vue';

/** The bit of Nuxt UI's `<UForm>` instance this needs. */
interface FormLike {
  setErrors(errors: { name?: string; message: string }[]): void;
}

/**
 * Lets `useFormAction` own a form and `<UForm>` render it: field errors from the client schema and from the server
 * (validation errors, and the ones a `fail()` attaches) are pushed into UForm, so each `<UFormField name>` shows its
 * own. useFormAction already drops an error once its field is edited, so the form clears as the user fixes it.
 * The nuxt-safe-action forms guide's Nuxt UI recipe, made reactive.
 */
export function useActionFormErrors(form: Readonly<Ref<FormLike | null | undefined>>, fieldErrors: Readonly<Ref<Record<string, string[]>>>): void {
  watch([form, fieldErrors], ([f, errors]) => f?.setErrors(toFormErrors(errors)), { immediate: true, deep: true });
}
